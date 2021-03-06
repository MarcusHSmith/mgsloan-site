{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- Copyright 2015 Ruud van Asseldonk
-- Copyright 2018 Michael G Sloan
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License version 3. See
-- the licence file in the root of the repository.
import Control.Exception (finally)
import Control.Monad
import Data.Monoid ((<>))
import Data.List (isInfixOf, sort, isSuffixOf)
import Data.Time.Calendar (toGregorian)
import Data.Time.Clock (getCurrentTime, utctDay)
import Minification (minifyHtml)
import System.Environment
import System.Directory
import System.FilePath
import System.Process (callProcess)
import Shelly hiding ((</>), FilePath)
import qualified Data.Text as T
import qualified Control.Concurrent.Async as Async
import qualified Data.Map as M
import qualified Image
import qualified Post as P
import qualified Template
import qualified Mode

-- Copies all files in the source directory to the destination directory.
copyFiles :: FilePath -> FilePath -> IO ()
copyFiles srcDir dstDir = do
  fps <- map (srcDir </>) <$> listDirectory srcDir
  forM_ fps $ \fp -> copyFile fp (dstDir </> takeFileName fp)

-- Reads and parses all templates in the given directory.
readTemplates :: FilePath -> IO (M.Map FilePath Template.Template)
readTemplates dir = do
  templates <- map (dir </>) <$> listDirectory dir
  fmap M.fromList $ forM templates $ \fp -> do
    contents <- readFile fp
    return (takeFileName fp, Template.parse contents)

-- Reads and renders all posts in the given directory.
readPosts :: FilePath -> IO [P.Post]
readPosts dir = do
  createDirectoryIfMissing True dir
  posts <- map (dir </>) <$> listDirectory dir
  fmap concat $ forM posts $ \postDir -> do
    let postName = takeFileName postDir
    if postName `elem` [".git", "license.md"]
      then return []
      else do
        let postPath = postDir </> "post.md"
        exists <- doesFileExist postPath
        if exists
          then (:[]) . P.parse postDir postName <$> readFile postPath
          else do
            putStrLn $ "Warning: expected file at " ++ postPath ++ ", but none found."
            return []

-- Holds the output directory and input image directory.
data Config = Config
  { outDir   :: FilePath
  , outMode  :: Mode.Mode
  }

copyPostImages :: Config -> P.Post -> IO ()
copyPostImages config post = do
  let destFile = (outDir config) </> (drop 1 $ P.url post) </> "index.html"
      destDir = takeDirectory destFile
      imagesDir = P.sourceDir post </> "images"
      destImagesDir = destDir </> "images"
  createDirectoryIfMissing True imagesDir
  createDirectoryIfMissing True destImagesDir
  copyFiles imagesDir destImagesDir

-- Given the post template and the global context, expands the template for all
-- of the posts and writes them to the output directory. This also prints a list
-- of processed posts to the standard output. Start numbering post artifacts at
-- 53, lower indices are reserved for other pages.
writePosts :: Template.Template -> Template.Context -> [P.Post] -> Config -> IO ()
writePosts tmpl ctx posts config =
  let
    total = length posts
    -- Reverse the list of posts, so the most recent one is rendered first.
    -- This makes the preview workflow faster, because the most recent post
    -- in the list is likely the one that I want to view.
    withRelated = zip [1 :: Int ..] $ reverse $ P.selectRelated posts
    writePostAsync (i, (post, related)) = do
      putStrLn $ "[" ++ (show i) ++ " of " ++ (show total) ++ "] " ++ (P.slug post)
      Async.async $ writePost post related
    writePost post related = do
      let destFile = (outDir config) </> (drop 1 $ P.url post) </> "index.html"
          context  = M.unions
            [ P.context post
            , P.relatedContext related
            , ctx]
          html = Template.apply tmpl context
          imagesDir = P.sourceDir post </> "images"
      withImages <- Image.processImages (outMode config) imagesDir (outDir config) html
      let minified = minifyHtml withImages
      writeFile destFile minified
  in do
    subsetCmdsAsync <- mapM writePostAsync withRelated
    mapM_ Async.wait subsetCmdsAsync

-- Writes a general (non-post) page given a template and expansion context.
-- Returns the subset commands that need to be executed for that page.
writePage :: String -> Template.Context -> Template.Template -> Config -> IO ()
writePage url pageContext template config = do
  let context  = Template.stringField "url" url <> pageContext
      html     = minifyHtml $ Template.apply template context
      destDir  = (outDir config) </> (tail url)
      destFile = destDir </> "index.html"
  createDirectoryIfMissing True destDir
  writeFile destFile html

-- Given the archive template and the global context, writes the archive page
-- to the destination directory.
writeArchive :: Template.Context -> Template.Template -> [P.Post] -> Config -> IO ()
writeArchive globalContext template posts = writePage "/" context template
  where
    context = M.unions
      [ P.archiveContext posts
      , Template.stringField "title"     "mgsloan"
      , Template.stringField "bold-font" "true"
      , Template.stringField "archive"   "true"
      , globalContext
      ]

-- Given the feed template and list of posts, writes an atom feed.
writeFeed :: Template.Template -> [P.Post] -> Config -> IO ()
writeFeed template posts config = do
  let url = "/feed.xml"
      context = P.feedContext posts
      atom = Template.apply template context
      destFile = (outDir config) </> (tail url)
  createDirectoryIfMissing True (outDir config)
  writeFile destFile atom

main :: IO ()
main = do
  chdirRepo False =<< getCurrentDirectory
  args <- getArgs
  case args of
    ["push"] -> pushCmd
    ["render-draft", draftTitlePortion] -> renderDraftCmd draftTitlePortion
    ["render-start"] -> renderStartPage
    [] -> regenerateCmd
    _ -> error $ "Unrecognized arguments: " ++ show args

chdirRepo :: Bool -> FilePath -> IO ()
chdirRepo dirChanged dir = do
  let dirName = takeFileName dir
  isGitRoot <- elem ".git" <$> listDirectory dir
  if isGitRoot && dirName `notElem` ["draft", "out"]
    then when dirChanged $ do
      putStrLn $ "Changing directory to " ++ show dir
      setCurrentDirectory dir
    else do
      chdirRepo True (takeDirectory dir)

renderDraftCmd :: String -> IO ()
renderDraftCmd draftTitlePortion = do
  templates <- readTemplates "templates/"
  drafts <- readPosts "draft/posts/"
  globalContext <- makeGlobalContext templates
  [draft] <- return $ filter ((draftTitlePortion `isInfixOf`) . P.title) drafts
  copyPostImages draftConfig draft
  writePosts (templates M.! "post.html") globalContext [draft] draftConfig

regenerateCmd :: IO ()
regenerateCmd = do
  templates <- readTemplates "templates/"
  posts <- readPosts "posts/"
  globalContext <- makeGlobalContext templates

  -- cleanOutputDir

  drafts <- (++) <$> readPosts "draft/posts/" <*> readPosts "draft/posts-old/"
  unless (null drafts) $ do
    putStrLn "Writing draft posts..."
    forM_ drafts (copyPostImages draftConfig)
    writePosts (templates M.! "post.html") globalContext drafts draftConfig
    putStrLn "Writing draft index..."
    writeArchive globalContext (templates M.! "archive.html") drafts draftConfig

  putStrLn "Writing posts..."
  forM_ posts (copyPostImages baseConfig)
  writePosts (templates M.! "post.html") globalContext posts baseConfig

  putStrLn "Copying old blog..."
  createDirectoryIfMissing True "out/wordpress"
  copyFiles "assets/old-blog/" "out/wordpress"

  putStrLn "Writing other pages..."
  writeArchive globalContext (templates M.! "archive.html") posts baseConfig

  copyFile "assets/favicon.png" "out/favicon.png"
  copyFile "assets/favicon.png" "draft/out/favicon.png"
  copyFile "assets/CNAME"       "out/CNAME"
  copyFile "assets/keybase.txt" "out/keybase.txt"
  copyFile "assets/dark-mode-toggle/src/dark-mode-toggle.mjs" "out/dark-mode-toggle.mjs"
  copyFile "assets/dark-mode-toggle/src/dark-mode-toggle.mjs" "draft/out/dark-mode-toggle.mjs"
  copyFile "assets/redirect-index.html" "out/posts/index.html"

  putStrLn "Writing atom feed..."
  writeFeed (templates M.! "feed.xml") posts baseConfig

  putStrLn "Using rsync to copy published posts into drafts"
  shelly $ run_ "rsync" ["-av", "out/posts", "draft/out/posts"]

-- Push to both repos.
pushCmd :: IO ()
pushCmd = shelly $ do
  liftIO cleanOutputDir
  -- Check if the repo is clean.
  -- https://stackoverflow.com/a/3879077
  let checkIsDirty = do
        errExit False $ run_ "git" ["diff-index", "--quiet", "HEAD", "--"]
        code <- lastExitCode
        return (code /= 0)
  isDirty <- checkIsDirty
  when isDirty $
    fail "Site repository appears to be dirty, so cannot push."
  let checkMaster repo = chdir repo $ do
        output <- run "git" ["rev-parse", "--abbrev-ref", "HEAD"]
        when (output /= "master\n") $
          fail $ show repo ++ " needs to be on master branch to push."
  -- Check if both repos are on master.
  checkMaster "."
  checkMaster "out"
  -- Rebuild the site.
  liftIO regenerateCmd
  liftIO renderStartPage
  -- Add all untracked and
  shouldPush <- chdir "out" $ do
    topLevel <- head . T.lines <$> run "git" ["rev-parse", "--show-toplevel"]
    curDir <- pwd
    when (fromText topLevel /= curDir) $ fail $ concat
      [ "Expected out dir git repo to be at "
      , show curDir
      , ", but instead it was at "
      , show topLevel
      ]
    run_ "git" ["add", "-A"]
    run_ "git" ["status"]
    echo_n "Does this status for the output repo look good? "
    response <- liftIO getLine
    case response :: String of
      "y" -> return True
      _ -> do
        echo "Response was not 'y', so not pushing"
        return False
  when shouldPush $ do
    run_ "git" ["push"]
    shortSha <- T.take 7 <$> run "git" ["rev-parse", "HEAD"]
    chdir "out" $ do
      outputDirty <- checkIsDirty
      if outputDirty
        then do
          run_ "git" ["commit", "-m", "Update to mgsloan/mgsloan-site@" <> shortSha]
          run_ "git" ["push"]
        else do
          echo "out/ repo is clean, so not committing or pushing it."

makeGlobalContext :: M.Map String Template.Template -> IO (M.Map String Template.ContextValue)
makeGlobalContext templates = do
  -- Create a context with the field "year" set to the current year, and create
  -- a context that contains all of the templates, to handle includes.
  (year, _month, _day) <- fmap (toGregorian . utctDay) getCurrentTime
  let yearString = show year
  return $ M.unions
    [ Template.stringField "year" yearString
    , Template.stringField "year-range" $
      if yearString == "2018"
        then "2018"
        else "2018-" ++ yearString
    , Template.stringField "body-font" "'Alegreya Sans'"
    , Template.stringField "header-font" "'Playfair Display'"
    , Template.stringField "serif-font" "Alegreya"
    , fmap Template.TemplateValue templates
    ]

cleanOutputDir :: IO ()
cleanOutputDir = do
  outExists <- doesDirectoryExist "out"
  when outExists $ do
    files <- listDirectory "out"
    print files
    forM_ files $ \file -> do
      let fp = "out" </> file
      if file == ".git"
        then return ()
        else do
          isFile <- doesFileExist fp
          print (fp, isFile)
          if isFile
            then removeFile fp
            else removeDirectoryRecursive fp

baseConfig :: Config
baseConfig = Config { outDir   = "out/"
                    , outMode  = Mode.Published
                    }

draftConfig :: Config
draftConfig = baseConfig { outDir = "draft/out"
                         , outMode = Mode.Draft
                         }

renderStartPage :: IO ()
renderStartPage = do
  prioritiesMd <- findFileWithSuffixIn "priorities.md" "/home/mgsloan/docs/weekly/"
  let prioritiesHtmlFile = "draft/priorities.html"
  callProcess "pandoc" [prioritiesMd, "-o", prioritiesHtmlFile]
  secretsHtml <- readFile "draft/start-page-secret.html"
  prioritiesHtml <- readFile prioritiesHtmlFile
  password <- head . lines <$> readFile "draft/start-page-password"
  let concatenatedHtmlFile = "draft/start-page-concatenated.html"
  writeFile concatenatedHtmlFile $ unlines
    [ "<div id=contents>"
    , secretsHtml
    , "<div id=priorities>"
    , prioritiesHtml
    , "</div>"
    , "</div>"
    ]
  -- staticrypt built from source of
  -- https://github.com/robinmoisson/staticrypt/tree/38a3f5b297b56c580a65cb2cadeb0007be88fe49
  createDirectoryIfMissing False "out/start-page"
  callProcess "staticrypt" [concatenatedHtmlFile, password, "-f", "templates/start-page.html", "-o", "out/start-page.html"]
    `finally` do
      removeFile prioritiesHtmlFile
      removeFile concatenatedHtmlFile

findFileWithSuffixIn :: String -> FilePath -> IO FilePath
findFileWithSuffixIn suffix weeklyDir = do
  entries <- sort <$> listDirectory weeklyDir
  let foundFileName = last $ filter ((suffix `isSuffixOf`) . takeFileName) entries
  return $ weeklyDir </> foundFileName

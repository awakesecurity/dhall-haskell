{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TypeOperators      #-}

module Main where

import Control.Exception (SomeException)
import Control.Monad (when)
import Data.Monoid (mempty, (<>))
import Data.Version (showVersion)
import Dhall.Core (normalize)
import Dhall.Import (Imported(..), load)
import Dhall.Parser (Src, exprAndHeaderFromText)
import Dhall.Pretty (annToAnsiStyle, prettyExpr)
import Dhall.TypeCheck (DetailedTypeError(..), TypeError, X)
import Options.Generic (Generic, ParseRecord, type (<?>)(..))
import System.Exit (exitFailure, exitSuccess)
import Text.Trifecta.Delta (Delta(..))

import qualified Paths_dhall as Meta

import qualified Control.Exception
import qualified Data.Text.Lazy.IO
import qualified Data.Text.Prettyprint.Doc                 as Pretty
import qualified Data.Text.Prettyprint.Doc.Render.Terminal as Pretty.Terminal
import qualified Data.Text.Prettyprint.Doc.Render.Text     as Pretty.Text
import qualified Dhall.Core
import qualified Dhall.TypeCheck
import qualified Options.Generic
import qualified System.Console.ANSI
import qualified System.IO

data Options = Options
    { explain :: Bool <?> "Explain error messages in more detail"
    , version :: Bool <?> "Display version and exit"
    , pretty  :: Bool <?> "Format output"
    } deriving (Generic)

instance ParseRecord Options

opts :: Pretty.LayoutOptions
opts =
    Pretty.defaultLayoutOptions
        { Pretty.layoutPageWidth = Pretty.AvailablePerLine 80 1.0 }

unbounded :: Pretty.LayoutOptions
unbounded = Pretty.LayoutOptions { Pretty.layoutPageWidth = Pretty.Unbounded }

main :: IO ()
main = do
    options <- Options.Generic.getRecord "Compiler for the Dhall language"
    when (unHelpful (version options)) $ do
      putStrLn (showVersion Meta.version)
      exitSuccess

    let handle =
                Control.Exception.handle handler2
            .   Control.Exception.handle handler1
            .   Control.Exception.handle handler0
          where
            handler0 e = do
                let _ = e :: TypeError Src X
                System.IO.hPutStrLn System.IO.stderr ""
                if unHelpful (explain options)
                    then Control.Exception.throwIO (DetailedTypeError e)
                    else do
                        Data.Text.Lazy.IO.hPutStrLn System.IO.stderr "\ESC[2mUse \"dhall --explain\" for detailed errors\ESC[0m"
                        Control.Exception.throwIO e

            handler1 (Imported ps e) = do
                let _ = e :: TypeError Src X
                System.IO.hPutStrLn System.IO.stderr ""
                if unHelpful (explain options)
                    then Control.Exception.throwIO (Imported ps (DetailedTypeError e))
                    else do
                        Data.Text.Lazy.IO.hPutStrLn System.IO.stderr "\ESC[2mUse \"dhall --explain\" for detailed errors\ESC[0m"
                        Control.Exception.throwIO (Imported ps e)

            handler2 e = do
                let _ = e :: SomeException
                System.IO.hSetEncoding System.IO.stderr System.IO.utf8
                System.IO.hPrint System.IO.stderr e
                System.Exit.exitFailure

    handle (do
        System.IO.hSetEncoding System.IO.stdin System.IO.utf8
        inText <- Data.Text.Lazy.IO.getContents

        (header, expr) <- case exprAndHeaderFromText (Directed "(stdin)" 0 0 0 0) inText of
            Left  err -> Control.Exception.throwIO err
            Right x   -> return x

        let render handle e = do
                supportsANSI <- System.Console.ANSI.hSupportsANSI handle
                let renderIO doc =
                        if supportsANSI
                        then Pretty.Terminal.renderIO handle (fmap annToAnsiStyle doc)
                        else Pretty.Text.renderIO handle (Pretty.unAnnotateS doc)

                if unHelpful (pretty options)
                    then do
                        let doc = Pretty.pretty header <> prettyExpr e
                        renderIO (Pretty.layoutSmart opts doc)
                    else do
                        let doc = prettyExpr e
                        renderIO (Pretty.layoutPretty unbounded doc)
                Data.Text.Lazy.IO.hPutStrLn handle ""


        expr' <- load expr

        typeExpr <- case Dhall.TypeCheck.typeOf expr' of
            Left  err      -> Control.Exception.throwIO err
            Right typeExpr -> return typeExpr

        render System.IO.stderr (normalize typeExpr)
        Data.Text.Lazy.IO.hPutStrLn System.IO.stderr mempty
        render System.IO.stdout (normalize expr') )

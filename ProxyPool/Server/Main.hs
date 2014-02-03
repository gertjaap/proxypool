{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}
-- | Entry point for proxy pool
module Main where

import ProxyPool.Network (configureKeepAlive, connectTimeout)
import ProxyPool.Handlers

import Control.Monad (forever, mzero, when)
import Control.Exception hiding (handle)
import Control.Concurrent (threadDelay)
import Control.Applicative ((<$>))

import System.Environment (getArgs)
import System.Posix.Signals (installHandler, sigPIPE, Handler(..))
import System.IO (stdout, IOMode(..))
import System.Exit (exitFailure)

import System.Log.Logger
import System.Log.Handler (setFormatter)
import System.Log.Handler.Simple
import System.Log.Formatter

import Data.Word
import Data.Aeson

import Data.Text as T
import Data.Text.Encoding as T
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL

import Network
import Network.Socket hiding (accept)

import Control.Monad.IO.Class
import Control.Monad.Trans.Maybe

import Control.Concurrent.Async

import qualified Database.Redis as R

-- | Manage incoming connections
listenDownstream :: GlobalState -> Word16 -> IO (Async ())
listenDownstream global port = do
    sock <- listenOn $ PortNumber $ fromIntegral port

    setSocketOption sock ReuseAddr 1
    setSocketOption sock NoDelay 1
    _ <- configureKeepAlive sock

    infoM "client" $ "Listening on localhost:" ++ show port
    -- listen for connections on separate thread
    async . forever $ do
        (handle, host, _) <- accept sock
        -- handle each incoming connection on a separate thread
        async $ bracket
                    (initaliseClient handle host global)
                    finaliseClient
                    (handleClient global)
                `catches` [ Handler $ \(e :: IOException) -> warningM "client" $ "IOException in client: " ++ show e
                          , Handler $ \(e :: ProxyPoolException) -> infoM "client" $ "Killed: " ++ show e
                          ]

-- | Manages Redis db connection
runDB :: GlobalState -> String -> Maybe B.ByteString -> IO (Async ())
runDB global host auth = async $ forever $ do
    infoM "db" $ "Connecting to " ++  host
    conn <- R.connect $ R.defaultConnectInfo { R.connectHost = host, R.connectAuth = auth }

    handleDB global conn `catches` [ Handler $ \(e :: IOException) -> warningM "db" $ "IOException in DB: " ++ show e
                                   , Handler $ \(_ :: R.ConnectionLostException) -> warningM "db" "Redis connection lost"
                                   ]

    warningM "db" "Sleeping for 5 seconds before reconnection"
    threadDelay $ 5 * 10^(6 :: Int)

-- | Handles connection to upstream pool server
runUpstream :: GlobalState -> String -> Word16 -> IO (Async ())
runUpstream global url port = async $ forever $ do
    upstream <- getAddrInfo
                    (Just $ defaultHints { addrFamily = AF_INET, addrSocketType = Stream })
                    (Just url)
                    (Just $ show port)

    case upstream of
        []  -> criticalM "server" "Could not resolve upstream server"
        x:_ -> bracket
                   (do
                        sock <- socket AF_INET Stream defaultProtocol
                        -- set up socket
                        setSocketOption sock NoDelay 1
                        _ <- configureKeepAlive sock

                        infoM "server" $ "Connecting to upstream: " ++ url ++ ":" ++ show port
                        connectTimeout sock (addrAddress x) 20

                        handle <- socketToHandle sock ReadWriteMode
                        initaliseServer handle
                   )
                   finaliseServer
                   (handleServer global)
               `catches` [ Handler $ \(e :: IOException) -> warningM "server" $ "IOException in server: " ++ show e
                         , Handler $ \(e :: ProxyPoolException) -> warningM "server" $ "Exception thrown: " ++ show e
                         ]

    warningM "server" "Sleeping for 5 seconds before reconnection"
    threadDelay $ 5 * 10^(6 :: Int)

main :: IO ()
main = withSocketsDo $ do
    -- read configuration from arguments
    args <- getArgs
    configFilePath <- case args of
        -- try loading configuration file from current directory
        []  -> return "proxypool.json"
        [x] -> return x
        _   -> do
            putStrLn "Usage: proxypool [proxypool.json]\n\tIf the configuration file is not specified, `proxypool.json` in the current directory is used instead"
            exitFailure

    -- load config file
    configResult <- eitherDecode <$> BL.readFile configFilePath
    config <- case configResult of
        Right x -> return x
        Left xs -> do
            putStrLn $ "Error reading config file (" ++ configFilePath ++ "): " ++ xs
            exitFailure

    -- start the logger
    logger <- flip setFormatter (tfLogFormatter "%F %T" "[$time][$loggername][$prio] $msg") <$> streamHandler stdout DEBUG
    updateGlobalLogger rootLoggerName $ setLevel DEBUG . setHandlers [logger]

    -- don't let the process die from a broken pipe
    _ <- installHandler sigPIPE Ignore Nothing

    infoM "main" $ "Starting server with config: " ++ configFilePath

    -- create the global global
    global <- initaliseGlobal config

    -- link together child threads
    (link =<<) $ listenDownstream global (_localPort config)
    (link =<<) $ runDB global (T.unpack $ _redisHost config) (T.encodeUtf8 <$> _redisAuth config)
    (link =<<) $ runUpstream global (T.unpack $ _upstreamHost config) (_upstreamPort config)

    -- hack to get control-c working
    _ <- runMaybeT $ forever $ do
        xs <- liftIO getLine
        when (xs == "exit") mzero

    return ()
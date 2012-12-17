{-# LANGUAGE TemplateHaskell, ScopedTypeVariables, ExistentialQuantification #-}
module Main where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar)
import qualified Control.Exception as Ex
import Control.Monad (forM_, forever)
import Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON))
import Data.Aeson.TH (deriveFromJSON, deriveJSON, deriveToJSON)
import Data.Function (on)
import Data.List (isInfixOf)
import System.Environment (getArgs)
import System.Environment.Executable (getExecutablePath)
import System.Posix.Signals (sigKILL)

import Test.Framework (Test, defaultMain, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import Test.HUnit (Assertion, assertEqual)

import RpcServer
import TestTools

--------------------------------------------------------------------------------
-- RPC-specific auxiliary                                                     --
--------------------------------------------------------------------------------

-- | Call the current executable and pass the right arguments
forkTestServer :: String -> IO RpcServer
forkTestServer test = do
  prog <- getExecutablePath
  forkRpcServer prog ["--server", test] Nothing

-- | Do an RPC call and verify the result
assertRpcEqual :: (ToJSON req, FromJSON resp, Show req, Show resp, Eq resp)
               => RpcServer -- ^ RPC server
               -> req       -- ^ Request
               -> resp      -- ^ Expected response
               -> Assertion
assertRpcEqual server req resp =
  assertRpcEquals server req [resp]

-- | Like 'assertRpcEqual' but verify a number of responses, before throwing
-- the specified exception (if any)
assertRpcEquals :: (ToJSON req, FromJSON resp, Show req, Show resp, Eq resp)
                => RpcServer -- ^ RPC server
                -> req       -- ^ Request
                -> [resp]    -- ^ Expected responses
                -> Assertion
assertRpcEquals server req resps =
  assertRpc server (Put req $ foldr Get Done resps)

data Conversation =
    forall req.  (ToJSON req) => Put req  Conversation
  | forall resp. (FromJSON resp, Show resp, Eq resp) => Get resp Conversation
  | Done

assertRpc :: RpcServer -> Conversation -> Assertion
assertRpc server conversation = do
  rpcConversation server $ \RpcConversation{..} ->
    let checkConversation Done =
          return ()
        checkConversation (Put req conv) = do
          put req
          checkConversation conv
        checkConversation (Get resp conv) = do
          assertEqual "" resp =<< get
          checkConversation conv
    in checkConversation conversation

isServerKilledException :: ExternalException -> Bool
isServerKilledException =
  ((==) `on` externalStdErr) (serverKilledException undefined)

isServerIOException :: Ex.IOException -> ExternalException -> Bool
isServerIOException ex =
  (== show ex) . externalStdErr

--------------------------------------------------------------------------------
-- Feature tests                                                              --
--------------------------------------------------------------------------------

-- | Simple echo server
testEcho :: RpcServer -> Assertion
testEcho server = assertRpcEqual server "ping" "ping"

testEchoServer :: RpcConversation -> IO ()
testEchoServer RpcConversation{..} = forever $ do
  req <- get :: IO String
  put req

-- | Test stateful server
testState :: RpcServer -> Assertion
testState server = forM_ ([0 .. 9] :: [Int]) $ assertRpcEqual server ()

testStateServer :: MVar Int -> RpcConversation -> IO ()
testStateServer st RpcConversation{..} = forever $ do
  () <- get
  modifyMVar_ st $ \i -> do
    put i
    return (i + 1)

-- | Test with request and response custom data types
data CountRequest  = Increment | GetCount deriving Show
data CountResponse = DoneCounting | Count Int deriving (Eq, Show)

$(deriveJSON id ''CountRequest)
$(deriveJSON id ''CountResponse)

testCustom :: RpcServer -> Assertion
testCustom server = do
  assertRpcEqual server GetCount (Count 0)
  assertRpcEqual server Increment DoneCounting
  assertRpcEqual server GetCount (Count 1)

testCustomServer :: MVar Int -> RpcConversation -> IO ()
testCustomServer st RpcConversation{..} = forever $ do
  req <- get
  case req of
    Increment -> modifyMVar_ st $ \i -> do
      put DoneCounting
      return (i + 1)
    GetCount -> modifyMVar_ st $ \i -> do
      put (Count i)
      return i

-- | Test progress messages
testProgress :: RpcServer -> Assertion
testProgress server =
  forM_ ([0 .. 9] :: [Int]) $ \i -> assertRpcEquals server i [i, i - 1 .. 0]

testProgressServer :: RpcConversation -> IO ()
testProgressServer RpcConversation{..} = forever $ do
  req <- get :: IO Int
  forM_ [req, req - 1 .. 1] $ put
  put (0 :: Int)

-- | Test shutdown
testShutdown :: RpcServer -> Assertion
testShutdown server = do
  assertRpcEqual server "ping" "ping"
  shutdown server
  assertRaises "" (== (userError "Manual shutdown"))
    (rpc server "ping" :: IO String)

-- | Test that stdout is available as usual on the server
testStdout :: RpcServer -> Assertion
testStdout server = do
  assertRpcEqual server "ping" "ping"
  shutdown server
  assertRaises "" (== (userError "Manual shutdown"))
    (rpc server "ping" :: IO String)

testStdoutServer :: RpcConversation -> IO ()
testStdoutServer RpcConversation{..} = forever $ do
  req <- get :: IO String
  putStrLn "   vvvv    testStdout intentionally printing to stdout"
  put req

-- | Test that we can do concurrent get and put
testConcurrentGetPut :: RpcServer -> Assertion
testConcurrentGetPut server =
  rpcConversation server $ \RpcConversation{..} -> do
    forkIO $ threadDelay 1000000 >> put ()
    get

testConcurrentGetPutServer :: RpcConversation -> IO ()
testConcurrentGetPutServer RpcConversation{..} = do
  () <- get
  put ()

--------------------------------------------------------------------------------
-- Test generalized conversations                                             --
--------------------------------------------------------------------------------

data StartGame  = StartGame Int Int
data Guess      = Guess Int | GiveUp | Yay      deriving (Eq, Show)
data GuessReply = GuessCorrect | GuessIncorrect deriving Show

$(deriveJSON id ''StartGame)
$(deriveJSON id ''Guess)
$(deriveJSON id ''GuessReply)

testConversation :: RpcServer -> Assertion
testConversation server = do
  assertRpc server
    $ Put (StartGame 1 10)
    $ Get (Guess 1)
    $ Put GuessIncorrect
    $ Get (Guess 2)
    $ Put GuessIncorrect
    $ Get (Guess 3)
    $ Put GuessCorrect
    $ Get Yay
    $ Done
  assertRpc server
    $ Put (StartGame 1 2)
    $ Get (Guess 1)
    $ Put GuessIncorrect
    $ Get (Guess 2)
    $ Put GuessIncorrect
    $ Get GiveUp
    $ Done
  assertRaises "" typeError $
    assertRpcEqual server GuessCorrect GiveUp
  where
    typeError :: ExternalException -> Bool
    typeError ExternalException{externalStdErr} =
      "expected" `isInfixOf` externalStdErr &&
      "but got"  `isInfixOf` externalStdErr

testConversationServer :: RpcConversation -> IO ()
testConversationServer RpcConversation{..} = forever $ do
    StartGame n m <- get
    go n m
  where
    go n m | n > m     = put GiveUp
           | otherwise = do put (Guess n)
                            answer <- get
                            case answer of
                              GuessCorrect   -> put Yay
                              GuessIncorrect -> go (n + 1) m

--------------------------------------------------------------------------------
-- Error handling tests                                                       --
--------------------------------------------------------------------------------

-- | Test crashing server
testCrash :: RpcServer -> Assertion
testCrash server =
  assertRaises "" (isServerIOException crash) $
    assertRpcEqual server () ()

testCrashServer :: RpcConversation -> IO ()
testCrashServer RpcConversation{..} = do
  () <- get
  Ex.throwIO crash

crash :: Ex.IOException
crash = userError "Intentional crash"

-- | Test server which gets killed during a request
testKill :: RpcServer -> Assertion
testKill server = do
  assertRpcEqual server "ping" "ping"   -- First request goes through
  assertRaises "" isServerKilledException $
    assertRpcEqual server "ping" "ping" -- Second does not

testKillServer :: MVar Bool -> RpcConversation -> IO ()
testKillServer firstRequest RpcConversation{..} = forever $ do
  req <- get :: IO String
  modifyMVar_ firstRequest $ \isFirst -> do
    if isFirst
      then put req
      else throwSignal sigKILL
    return False

-- | Test server which gets killed between requests
testKillAsync :: RpcServer -> Assertion
testKillAsync server = do
  assertRpcEqual server "ping" "ping"
  threadDelay 500000 -- Wait for server to exit
  assertRaises "" isServerKilledException $
    assertRpcEqual server "ping" "ping"

testKillAsyncServer :: RpcConversation -> IO ()
testKillAsyncServer RpcConversation{..} = forever $ do
  req <- get :: IO String
  -- Fork a thread which causes the server to crash 0.5 seconds after the request
  forkIO $ threadDelay 250000 >> throwSignal sigKILL
  put req

-- | Test crash during decoding
data TypeWithFaultyDecoder = TypeWithFaultyDecoder deriving Show

instance FromJSON TypeWithFaultyDecoder where
  parseJSON _ = fail "Faulty decoder"

$(deriveToJSON id ''TypeWithFaultyDecoder)

testFaultyDecoder :: RpcServer -> Assertion
testFaultyDecoder server =
  assertRaises "" (isServerIOException (userError "Faulty decoder")) $
    assertRpcEqual server TypeWithFaultyDecoder ()

testFaultyDecoderServer :: RpcConversation -> IO ()
testFaultyDecoderServer RpcConversation{..} = forever $ do
  TypeWithFaultyDecoder <- get
  put ()

-- | Test crash during encoding
data TypeWithFaultyEncoder = TypeWithFaultyEncoder deriving (Show, Eq)

$(deriveFromJSON id ''TypeWithFaultyEncoder)

instance ToJSON TypeWithFaultyEncoder where
  toJSON _ = error "Faulty encoder"

testFaultyEncoder :: RpcServer -> Assertion
testFaultyEncoder server =
  assertRaises "" ((== "Faulty encoder") . externalStdErr) $
    assertRpcEqual server () TypeWithFaultyEncoder

testFaultyEncoderServer :: RpcConversation -> IO ()
testFaultyEncoderServer RpcConversation{..} = forever $ do
  () <- get
  put TypeWithFaultyEncoder

--------------------------------------------------------------------------------
-- Test errors during RPC calls with multiple responses                       --
--------------------------------------------------------------------------------

-- | Test server which crashes after sending some intermediate responses
testCrashMulti :: RpcServer -> Assertion
testCrashMulti server =
  assertRaises "" (isServerIOException crash) $
    assertRpcEquals server (3 :: Int) ([3, 2, 1, 0] :: [Int])

testCrashMultiServer :: RpcConversation -> IO ()
testCrashMultiServer RpcConversation{..} = forever $ do
  req <- get :: IO Int
  forM_ [req, req - 1 .. 1] $ put
  Ex.throwIO crash

-- | Like 'CrashMulti', but killed rather than an exception
testKillMulti :: RpcServer -> Assertion
testKillMulti server =
  assertRaises "" isServerKilledException $
    assertRpcEquals server (3 :: Int) ([3, 2, 1, 0] :: [Int])

testKillMultiServer :: RpcConversation -> IO ()
testKillMultiServer RpcConversation{..} = forever $ do
  req <- get :: IO Int
  forM_ [req, req - 1 .. 1] $ put
  throwSignal sigKILL

-- | Like 'KillMulti', but now the server gets killed *between* messages
testKillAsyncMulti :: RpcServer -> Assertion
testKillAsyncMulti server =
  assertRaises "" isServerKilledException $
    assertRpcEquals server (3 :: Int) ([3, 2, 1, 0] :: [Int])

testKillAsyncMultiServer :: RpcConversation -> IO ()
testKillAsyncMultiServer RpcConversation{..} = forever $ do
  req <- get
  forkIO $ threadDelay (250000 + (req - 1) * 50000) >> throwSignal sigKILL
  forM_ [req, req - 1 .. 1] $ \i -> threadDelay 50000 >> put i

--------------------------------------------------------------------------------
-- Tests for errors in client code                                            --
--------------------------------------------------------------------------------

-- | Test letting the Progress object escape from the scope
testIllscoped :: RpcServer -> Assertion
testIllscoped server = do
  conversation <- rpcConversation server $ return
  assertRaises "" (== illscopedConversationException) (get conversation :: IO String)
  assertRaises "" (== illscopedConversationException) (put conversation "hi")

-- | Test what happens if the client specifies the wrong request type
--
-- (The actual type is the type of the echo server: RpcServer String String)
testInvalidReqType :: RpcServer -> Assertion
testInvalidReqType server =
    assertRaises "" (isServerIOException (userError parseEx)) $
      assertRpcEqual server () "ping"
  where
    -- TODO: do we want to insist on this particular parse error?
    parseEx = "when expecting a String, encountered Array instead"

-- | Test what happens if the client specifies the wrong response type
--
-- Note that since the decoding error now happens *locally*, the exception
-- is a regular userError, rather than an ExternalException
--
-- (The actual type is the type of the echo server: RpcServer String String)
testInvalidRespType :: RpcServer -> Assertion
testInvalidRespType server =
    assertRaises "" (== userError parseEx) $
      assertRpcEqual server "ping" ()
  where
    -- TODO: do we want to insist on this particular parse error?
    parseEx = "when expecting a (), encountered String instead"

--------------------------------------------------------------------------------
-- Driver                                                                     --
--------------------------------------------------------------------------------

tests :: [Test]
tests = [
    testGroup "Features" [
        testRPC "echo"             testEcho
      , testRPC "state"            testState
      , testRPC "custom"           testCustom
      , testRPC "progress"         testProgress
      , testRPC "shutdown"         testShutdown
      , testRPC "stdout"           testStdout
      , testRPC "conversation"     testConversation
      , testRPC "concurrentGetPut" testConcurrentGetPut
      ]
  , testGroup "Error handling" [
        testRPC "crash"            testCrash
      , testRPC "kill"             testKill
      , testRPC "killAsync"        testKillAsync
      , testRPC "faultyDecoder"    testFaultyDecoder
      , testRPC "faultyEncoder"    testFaultyEncoder
      ]
   , testGroup "Error handling during RPC calls with multiple responses" [
         testRPC "crashMulti"       testCrashMulti
       , testRPC "killMulti"        testKillMulti
       , testRPC "killAsyncMulti"   testKillAsyncMulti
       ]
   , testGroup "Client code errors" [
         testRPC "illscoped"        testIllscoped
       , testRPC "invalidReqType"   testInvalidReqType
       , testRPC "invalidRespType"  testInvalidRespType
       ]
  ]
  where
    testRPC :: String -> (RpcServer -> Assertion) -> Test
    testRPC name testWith = testCase name $ do
      server <- forkTestServer name
      testWith server
      shutdown server

main :: IO ()
main = do
  args <- getArgs
  case args of
    "--server" : test : args' -> case test of
      "echo"             -> rpcServer args' testEchoServer
      "state"            -> do st <- newMVar 0
                               rpcServer args' (testStateServer st)
      "custom"           -> do st <- newMVar 0
                               rpcServer args' (testCustomServer st)
      "progress"         -> rpcServer args' testProgressServer
      "shutdown"         -> rpcServer args' testEchoServer
      "stdout"           -> rpcServer args' testStdoutServer
      "conversation"     -> rpcServer args' testConversationServer
      "concurrentGetPut" -> rpcServer args' testConcurrentGetPutServer
      "crash"            -> rpcServer args' testCrashServer
      "kill"             -> do firstRequest <- newMVar True
                               rpcServer args' (testKillServer firstRequest)
      "killAsync"        -> rpcServer args' testKillAsyncServer
      "faultyDecoder"    -> rpcServer args' testFaultyDecoderServer
      "faultyEncoder"    -> rpcServer args' testFaultyEncoderServer
      "illscoped"        -> rpcServer args' testEchoServer
      "underconsumption" -> rpcServer args' testEchoServer
      "overconsumption"  -> rpcServer args' testEchoServer
      "crashMulti"       -> rpcServer args' testCrashMultiServer
      "killMulti"        -> rpcServer args' testKillMultiServer
      "killAsyncMulti"   -> rpcServer args' testKillAsyncMultiServer
      "invalidReqType"   -> rpcServer args' testEchoServer
      "invalidRespType"  -> rpcServer args' testEchoServer
      _ -> error $ "Invalid server " ++ show test
    _ -> defaultMain tests

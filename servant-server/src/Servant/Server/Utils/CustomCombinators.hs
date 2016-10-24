{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- fixme: document phases
-- fixme: add doctests
-- fixme: document that the req body can only be consumed once
-- fixme: document dependency problem

module Servant.Server.Utils.CustomCombinators (

  -- * ServerCombinator

  ServerCombinator,
  runServerCombinator,

  -- * Constructing ServerCombinators

  makeCaptureCombinator,
  makeRequestCheckCombinator,
  makeAuthCombinator,
  makeReqBodyCombinator,
  makeCombinator,

  -- * Re-exports

  RouteResult(..),
) where

import           Control.Monad.IO.Class
import           Control.Exception (throwIO, ErrorCall(..))
import           Data.ByteString
import           Data.Proxy
import           Data.Text
import           Network.Wai

import           Servant.API
import           Servant.Server
import           Servant.Server.Internal

data ServerCombinator combinator serverType api context where
  CI :: (forall env .
    Proxy (combinator :> api)
    -> Context context
    -> Delayed env serverType
    -> Router' env RoutingApplication)
    -> ServerCombinator combinator serverType api context

runServerCombinator :: ServerCombinator combinator serverType api context
  -> Proxy (combinator :> api)
  -> Context context
  -> Delayed env serverType
  -> Router' env RoutingApplication
runServerCombinator (CI i) = i

makeCaptureCombinator ::
  (HasServer api context) =>
  (Context context -> Text -> IO (RouteResult arg))
  -> ServerCombinator combinator (arg -> ServerT api Handler) api context
makeCaptureCombinator = inner -- we use 'inner' to avoid having 'forall' show up in haddock docs
  where
    inner ::
      forall api combinator arg context .
      (HasServer api context) =>
      (Context context -> Text -> IO (RouteResult arg))
      -> ServerCombinator combinator (arg -> ServerT api Handler) api context
    inner getArg = CI $ \ Proxy context delayed ->
      CaptureRouter $
      route (Proxy :: Proxy api) context $ addCapture delayed $ \ captured ->
      (liftRouteResult =<< liftIO (getArg context captured))

makeRequestCheckCombinator ::
  (HasServer api context) =>
  (Context context -> Request -> IO (RouteResult ()))
  -> ServerCombinator combinator (ServerT api Handler) api context
makeRequestCheckCombinator = inner
  where
    inner ::
      forall api combinator context .
      (HasServer api context) =>
      (Context context -> Request -> IO (RouteResult ()))
      -> ServerCombinator combinator (ServerT api Handler) api context
    inner check = CI $ \ Proxy context delayed ->
      route (Proxy :: Proxy api) context $ addMethodCheck delayed $
      withRequest $ \ request ->
        liftRouteResult =<< liftIO (check context (protectBody "makeRequestCheckCombinator" request))

makeAuthCombinator ::
  (HasServer api context) =>
  (Context context -> Request -> IO (RouteResult arg))
  -> ServerCombinator combinator (arg -> ServerT api Handler) api context
makeAuthCombinator = inner
  where
    inner ::
      forall api combinator arg context .
      (HasServer api context) =>
      (Context context -> Request -> IO (RouteResult arg))
      -> ServerCombinator combinator (arg -> ServerT api Handler) api context
    inner authCheck = CI $ \ Proxy context delayed ->
      route (Proxy :: Proxy api) context $ addAuthCheck delayed $
      withRequest $ \ request ->
        liftRouteResult =<< liftIO (authCheck context (protectBody "makeAuthCombinator" request))

makeReqBodyCombinator ::
  (HasServer api context) =>
  (Context context -> IO ByteString -> arg)
  -> ServerCombinator combinator (arg -> ServerT api Handler) api context
makeReqBodyCombinator = inner
  where
    inner ::
      forall api combinator arg context .
      (HasServer api context) =>
      (Context context -> IO ByteString -> arg)
      -> ServerCombinator combinator (arg -> ServerT api Handler) api context
    inner getArg = CI $ \ Proxy context delayed ->
      route (Proxy :: Proxy api) context $ addBodyCheck delayed
      (return ())
      (\ () -> withRequest $ \ request ->
        liftRouteResult $ Route $ getArg context $ requestBody request)

makeCombinator ::
  (HasServer api context) =>
  (Context context -> Request -> IO (RouteResult arg))
  -> ServerCombinator combinator (arg -> ServerT api Handler) api context
makeCombinator = inner
  where
    inner ::
      forall api combinator arg context .
      (HasServer api context) =>
      (Context context -> Request -> IO (RouteResult arg))
      -> ServerCombinator combinator (arg -> ServerT api Handler) api context
    inner getArg = CI $ \ Proxy context delayed ->
      route (Proxy :: Proxy api) context $ addBodyCheck delayed
      (return ())
      (\ () -> withRequest $ \ request ->
        liftRouteResult =<< liftIO (getArg context (protectBody "makeCombinator" request)))

protectBody :: String -> Request -> Request
protectBody name request = request{
  requestBody = throwIO $ ErrorCall $
    "ERROR: " ++ name ++ ": combinator must not access the request body"
}

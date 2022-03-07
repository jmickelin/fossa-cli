{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Control.Carrier.Telemetry (
  TelemetryC,
  IgnoreTelemetryC,
  withTelemetry,
  withoutTelemetry,
  bracket',
) where

import Control.Concurrent.STM (atomically, putTMVar, tryReadTMVar)
import Control.Concurrent.STM.TBMQueue (tryWriteTBMQueue)
import Control.Effect.Exception (Exception (fromException), catch, mask, throwIO)
import Control.Effect.Lift (Lift, sendIO)
import Control.Effect.Telemetry (Telemetry (..))
import Control.Monad (void, when)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Maybe (isNothing)

import App.Fossa.Telemetry.Types (
  TelemetryCtx (..),
  TelemetryTimeSpent (TelemetryTimeSpent),
  TimedLogRecord (TimedLogRecord),
 )
import App.Fossa.Telemetry.Utils (
  mkTelemetryCtx,
  mkTelemetryRecord,
  timeItT,
 )
import Control.Exception qualified as Exc
import Data.Time.Clock (getCurrentTime)
import Data.Tracing.Instrument (incCount)
import System.Exit (ExitCode (ExitSuccess))

import App.Fossa.Telemetry.Sink.Common (emitTelemetry)
import Control.Algebra (Algebra (alg), Has, type (:+:) (L, R))
import Control.Carrier.Reader (ReaderC, ask, runReader)

newtype TelemetryC m a = TelemetryC {runTelemetryC :: ReaderC TelemetryCtx m a}
  deriving (Applicative, Functor, Monad, MonadFail, MonadIO)

instance (Algebra sig m, MonadIO m, Has (Lift IO) sig m) => Algebra (Telemetry :+: sig) (TelemetryC m) where
  alg hdl sig ctx = case sig of
    L op -> do
      telCtx <- TelemetryC (ask @(TelemetryCtx))
      case op of
        SetTelemetrySink sink -> do
          maybeSink <- sendIO $ atomically $ tryReadTMVar (telSink telCtx)
          when (isNothing maybeSink) $
            sendIO $ atomically $ putTMVar (telSink telCtx) sink
          ctx <$ pure ()
        TrackUsage feat -> do
          ctx <$ (sendIO . atomically $ incCount feat $ telCounters telCtx)
        TrackConfig cmd cfg -> do
          maybeCfg <- sendIO $ atomically $ tryReadTMVar (telFossaConfig telCtx)
          case maybeCfg of
            Nothing -> ctx <$ sendIO (atomically $ putTMVar (telFossaConfig telCtx) (cmd, cfg))
            Just _ -> ctx <$ pure ()
        TrackTimeSpent computeName act -> do
          (timeTook, res) <- timeItT (hdl (act <$ ctx))
          void $ sendIO (atomically $ tryWriteTBMQueue (telTimeSpent telCtx) (TelemetryTimeSpent computeName timeTook))
          pure res
        TrackRawLogMessage sev msg -> do
          currentTime <- sendIO getCurrentTime
          ctx <$ sendIO (atomically $ tryWriteTBMQueue (telLogsQ telCtx) (TimedLogRecord currentTime sev msg))
    R other -> TelemetryC (alg (runTelemetryC . hdl) (R other) ctx)

-- | Runs Telemetry Effect
--
-- Telemetry is automatically emitted to telemetry sink. When telemetry sink is not set
-- collected telemetry data is discarded. Telemetry internally uses @bracket'@ so,
-- telemetry is emitted even when, 'SomeException' are thrown.
--
-- __Examples:__
--
-- @
-- main :: IO ()
-- main = withTelemetry foo
--
-- foo :: Has Telemetry sig m => m ()
-- foo = do
--  trackRawMessage SevDebug "foo something happened !!"
--  pure ()
-- @
withTelemetry :: Has (Lift IO) sig m => TelemetryC m a -> m a
withTelemetry action =
  bracket'
    mkTelemetryCtx
    teardownTelemetry
    $ \ctx -> runReader ctx . runTelemetryC $ action
  where
    teardownTelemetry ctx hadFatalException = do
      telSink <- sendIO . atomically $ tryReadTMVar (telSink ctx)
      case telSink of
        Nothing -> pure ()
        Just sink -> emitTelemetry sink =<< mkTelemetryRecord hadFatalException ctx

-- | Modified bracket where teardown callback function is aware if the exception was fatal or not.
-- Any exceptions that are not ExitSuccess IO exception, are considered to be fatal.
bracket' :: forall sig m a b c. Has (Lift IO) sig m => m a -> (a -> Bool -> m b) -> (a -> m c) -> m c
bracket' create teardown act =
  mask $ \restore -> do
    resource <- create
    r <- restore (act resource) `onException` teardown resource
    _ <- teardown resource False
    pure r
  where
    onException :: m x -> (Bool -> m y) -> m x
    onException io actOnException =
      io `catch` \e -> do
        let hadFatalException = case fromException e of
              Just ExitSuccess -> False
              _ -> True
        actOnException hadFatalException >> throwIO (e :: Exc.SomeException)

newtype IgnoreTelemetryC m a = IgnoreTelemetryC {runIgnoreTelemetryC :: m a}
  deriving (Applicative, Functor, Monad, MonadFail, MonadIO)

instance Algebra sig m => Algebra (Telemetry :+: sig) (IgnoreTelemetryC m) where
  alg hdl sig ctx = case sig of
    L op -> do
      case op of
        TrackUsage{} -> pure ctx
        TrackConfig{} -> pure ctx
        SetTelemetrySink{} -> pure ctx
        TrackRawLogMessage{} -> pure ctx
        (TrackTimeSpent _ act) -> hdl (act <$ ctx)
    R other -> alg (IgnoreTelemetryC . runIgnoreTelemetryC . hdl) (R other) ctx

-- | Ignores all telemetry effects.
withoutTelemetry :: IgnoreTelemetryC m a -> m a
withoutTelemetry = runIgnoreTelemetryC
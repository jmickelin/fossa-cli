module App.Fossa.Configuration.TelemetryConfigSpec (
  spec,
) where

import App.Fossa.Config.Common (
  CommonOpts (..),
  collectTelemetryScope,
 )
import App.Fossa.Config.ConfigFile (
  ConfigFile (..),
  ConfigTelemetryScope (FullTelemetry, NoTelemetry),
 )
import App.Fossa.Config.EnvironmentVars (EnvVars (..))
import App.Fossa.Telemetry.Sink.Common (
  TelemetrySink (
    TelemetrySinkToEndpoint,
    TelemetrySinkToFile
  ),
 )
import Data.Text (Text)
import Fossa.API.Types (
  ApiKey (ApiKey),
  ApiOpts (ApiOpts),
 )
import Test.Effect (it', shouldBe')
import Test.Hspec (Spec, describe)

defaultEnvVars :: EnvVars
defaultEnvVars =
  EnvVars
    { envApiKey = Nothing
    , envConfigDebug = False
    , envTelemetryDebug = False
    , envTelemetryScope = Nothing
    }

defaultCommonOpts :: CommonOpts
defaultCommonOpts =
  CommonOpts
    { optDebug = False
    , optBaseUrl = Nothing
    , optProjectName = Nothing
    , optProjectRevision = Nothing
    , optAPIKey = Nothing
    , optConfig = Nothing
    , optTelemetry = Nothing
    }

defaultConfigFile :: ConfigFile
defaultConfigFile =
  ConfigFile
    { configVersion = 3
    , configServer = Nothing
    , configApiKey = Just mockApiKeyRaw
    , configProject = Nothing
    , configRevision = Nothing
    , configTargets = Nothing
    , configPaths = Nothing
    , configExperimental = Nothing
    , configTelemetryScope = Nothing
    }

mockApiKeyRaw :: Text
mockApiKeyRaw = "mockTelemetryApiKey"

mockApiKey :: ApiKey
mockApiKey = ApiKey mockApiKeyRaw

noConfig :: Maybe ConfigFile
noConfig = Nothing

noOpts :: Maybe CommonOpts
noOpts = Nothing

spec :: Spec
spec = do
  describe "telemetry configuration" $ do
    describe "command opts" $ do
      it' "should set sink to nothing, when off scope is provided via command opts" $ do
        sink <-
          collectTelemetryScope
            noConfig
            defaultEnvVars
            (Just defaultCommonOpts{optTelemetry = Just NoTelemetry, optAPIKey = Just mockApiKeyRaw})
        sink `shouldBe'` Nothing

      it' "should set sink to endpoint, when full scope is provided via command opts" $ do
        sink <-
          collectTelemetryScope
            noConfig
            defaultEnvVars
            (Just defaultCommonOpts{optTelemetry = Just FullTelemetry, optAPIKey = Just mockApiKeyRaw})
        sink `shouldBe'` Just (TelemetrySinkToEndpoint (ApiOpts Nothing mockApiKey))

      it' "should set sink to file, when debug option is provided via command line" $ do
        telFull <-
          collectTelemetryScope
            noConfig
            defaultEnvVars
            (Just defaultCommonOpts{optTelemetry = Just FullTelemetry, optDebug = True, optAPIKey = Just mockApiKeyRaw})
        telFull `shouldBe'` Just TelemetrySinkToFile

        telOff <-
          collectTelemetryScope
            noConfig
            defaultEnvVars
            (Just defaultCommonOpts{optTelemetry = Just FullTelemetry, optDebug = True, optAPIKey = Just mockApiKeyRaw})
        telOff `shouldBe'` Just TelemetrySinkToFile

    describe "environment variables" $ do
      it' "should set sink to nothing, when off scope is provided via environment variables" $ do
        sink <-
          collectTelemetryScope
            noConfig
            defaultEnvVars{envTelemetryScope = Just NoTelemetry, envApiKey = Just mockApiKeyRaw}
            noOpts
        sink `shouldBe'` Nothing

      it' "should set sink to endpoint, when full scope is provided via environment variables" $ do
        sink <-
          collectTelemetryScope
            noConfig
            defaultEnvVars{envTelemetryScope = Just FullTelemetry, envApiKey = Just mockApiKeyRaw}
            noOpts
        sink `shouldBe'` Just (TelemetrySinkToEndpoint (ApiOpts Nothing mockApiKey))

      it' "should set sink to file, when debug option is provided via environment variable" $ do
        telFull <-
          collectTelemetryScope
            noConfig
            defaultEnvVars
              { envTelemetryScope = Just FullTelemetry
              , envApiKey = Just mockApiKeyRaw
              , envTelemetryDebug = True
              }
            noOpts
        telFull `shouldBe'` Just TelemetrySinkToFile

        telOff <-
          collectTelemetryScope
            noConfig
            defaultEnvVars
              { envTelemetryScope = Just NoTelemetry
              , envApiKey = Just mockApiKeyRaw
              , envTelemetryDebug = True
              }
            noOpts
        telOff `shouldBe'` Just TelemetrySinkToFile

    describe "configuration file" $ do
      it' "should set sink to nothing, when off scope is provided via configuration file" $ do
        sink <-
          collectTelemetryScope
            ( Just defaultConfigFile{configTelemetryScope = Just NoTelemetry}
            )
            defaultEnvVars
            noOpts
        sink `shouldBe'` Nothing

      it' "should set sink to endpoint, when full scope is provided via configuration file" $ do
        sink <-
          collectTelemetryScope
            ( Just defaultConfigFile{configTelemetryScope = Just FullTelemetry}
            )
            defaultEnvVars
            noOpts
        sink `shouldBe'` Just (TelemetrySinkToEndpoint (ApiOpts Nothing mockApiKey))
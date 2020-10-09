module Strategy.Cocoapods
  ( discover,
  )
where

import Control.Applicative ((<|>))
import Control.Effect.Diagnostics (Diagnostics, (<||>))
import qualified Control.Effect.Diagnostics as Diag
import Control.Monad.IO.Class
import Discovery.Walk
import Effect.ReadFS
import Graphing
import Path
import qualified Strategy.Cocoapods.Podfile as Podfile
import qualified Strategy.Cocoapods.PodfileLock as PodfileLock
import Types

discover :: MonadIO m => Path Abs Dir -> m [DiscoveredProject]
discover dir = map mkProject <$> findProjects dir

findProjects :: MonadIO m => Path Abs Dir -> m [CocoapodsProject]
findProjects = walk' $ \dir _ files -> do
  let podfile = findFileNamed "Podfile" files
  let podfileLock = findFileNamed "Podfile.lock" files

  let project =
        CocoapodsProject
          { cocoapodsPodfile = podfile,
            cocoapodsPodfileLock = podfileLock,
            cocoapodsDir = dir
          }

  case podfile <|> podfileLock of
    Nothing -> pure ([], WalkContinue)
    Just _ -> pure ([project], WalkContinue)

data CocoapodsProject = CocoapodsProject
  { cocoapodsPodfile :: Maybe (Path Abs File),
    cocoapodsPodfileLock :: Maybe (Path Abs File),
    cocoapodsDir :: Path Abs Dir
  }
  deriving (Eq, Ord, Show)

mkProject :: CocoapodsProject -> DiscoveredProject
mkProject project =
  DiscoveredProject
    { projectType = "cocoapods",
      projectBuildTargets = mempty,
      projectDependencyGraph = const . runReadFSIO $ getDeps project,
      projectPath = cocoapodsDir project,
      projectLicenses = pure []
    }

getDeps :: (Has ReadFS sig m, Has Diagnostics sig m) => CocoapodsProject -> m (Graphing Dependency)
getDeps project = analyzePodfileLock project <||> analyzePodfile project

analyzePodfile :: (Has ReadFS sig m, Has Diagnostics sig m) => CocoapodsProject -> m (Graphing Dependency)
analyzePodfile project = Diag.fromMaybeText "No Podfile present in the project" (cocoapodsPodfile project) >>= Podfile.analyze'

analyzePodfileLock :: (Has ReadFS sig m, Has Diagnostics sig m) => CocoapodsProject -> m (Graphing Dependency)
analyzePodfileLock project = Diag.fromMaybeText "No Podfile.lock present in the project" (cocoapodsPodfileLock project) >>= PodfileLock.analyze'
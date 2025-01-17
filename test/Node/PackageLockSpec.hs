{-# LANGUAGE TemplateHaskell #-}

module Node.PackageLockSpec (
  spec,
) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import DepTypes (
  DepEnvironment (EnvDevelopment, EnvProduction),
  DepType (NodeJSType),
  Dependency (..),
  VerConstraint (CEq),
 )
import Effect.ReadFS (readContentsJson)
import GraphUtil (
  expectDep,
  expectDeps,
  expectDeps',
  expectDirect,
  expectDirect',
  expectEdges,
  expectEdges',
 )
import Path (Abs, Dir, Path, mkRelDir, mkRelFile, (</>))
import Path.IO (getCurrentDir)
import Strategy.Node.Npm.PackageLock (
  NpmResolved (NpmResolved, unNpmResolved),
  PkgLockDependency (
    PkgLockDependency,
    depDependencies,
    depDev,
    depRequires,
    depResolved,
    depVersion
  ),
  PkgLockJson (..),
  PkgLockPackage (PkgLockPackage),
  buildGraph,
  pkgPeerDeps,
  pkgResolved,
 )
import Test.Effect (it', shouldBe')
import Test.Hspec (Spec, describe, it, runIO)

-- This is a package-lock.json that has a dev dependency (packageOne) with a
-- require, packageTwo, that doesn't exist in either depDependencies or
-- lockDependencies.
mockRequiredMissingDep :: PkgLockJson
mockRequiredMissingDep =
  PkgLockJson
    { lockDependencies =
        Map.fromList
          [
            ( "packageOne"
            , PkgLockDependency
                { depVersion = "1.0.0"
                , depDev = True
                , depResolved = NpmResolved $ Just "https://foo.com"
                , depRequires = Map.fromList [("packageTwo", "2.0.0")]
                , depDependencies = Map.empty
                }
            )
          ,
            ( "packageThree"
            , PkgLockDependency
                { depVersion = "3.0.0"
                , depDev = False
                , depResolved = NpmResolved $ Just "https://bar.com"
                , depRequires = Map.empty
                , depDependencies = Map.empty
                }
            )
          ]
    , lockPackages = Map.empty
    }

mockDevRequireMissingDependency :: Dependency
mockDevRequireMissingDependency =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "packageTwo"
    , dependencyVersion = Just (CEq "2.0.0")
    , dependencyLocations = []
    , dependencyEnvironments = Set.singleton EnvDevelopment
    , dependencyTags = Map.empty
    }

mockNameSpacedPeerDepLock :: PkgLockJson
mockNameSpacedPeerDepLock =
  PkgLockJson
    { lockPackages =
        Map.fromList
          [
            ( "node_modules/@ns/packageOne"
            , PkgLockPackage
                { pkgPeerDeps = Map.fromList [("packageTwo", "2.0.0")]
                , pkgResolved = Just "https://package-one.com/one.tgz"
                }
            )
          ]
    , lockDependencies =
        Map.fromList
          [
            ( "@ns/packageOne"
            , PkgLockDependency
                { depVersion = "1.0.0"
                , depDev = False
                , depResolved = NpmResolved $ Just "https://package-one.com/one.tgz"
                , depRequires = Map.empty -- Map.fromList [("packageThree", "3.0.0")]
                , depDependencies = Map.empty
                }
            )
          ,
            ( "packageTwo"
            , PkgLockDependency
                { depVersion = "2.0.0"
                , depDev = False
                , depResolved = NpmResolved $ Just "https://package-two.com/two.tgz"
                , depRequires = Map.empty
                , depDependencies = Map.empty
                }
            )
          ]
    }

mockNSPeerDepPackageOne :: Dependency
mockNSPeerDepPackageOne =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "@ns/packageOne"
    , dependencyVersion = Just (CEq "1.0.0")
    , dependencyLocations = ["https://package-one.com/one.tgz"]
    , dependencyEnvironments = Set.singleton EnvProduction
    , dependencyTags = Map.empty
    }

mockNSPeerDepPackageTwo :: Dependency
mockNSPeerDepPackageTwo =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "packageTwo"
    , dependencyVersion = Just (CEq "2.0.0")
    , dependencyLocations = ["https://package-two.com/two.tgz"]
    , dependencyEnvironments = Set.singleton EnvProduction
    , dependencyTags = Map.empty
    }

mockInput :: PkgLockJson
mockInput =
  PkgLockJson
    { lockPackages = Map.empty
    , lockDependencies =
        Map.fromList
          [
            ( "packageOne"
            , PkgLockDependency
                { depVersion = "1.0.0"
                , depDev = False
                , depResolved = NpmResolved $ Just "https://example.com/one.tgz"
                , depRequires = Map.fromList [("packageTwo", "2.0.0"), ("packageSeven", "7.0.0")]
                , depDependencies =
                    Map.fromList
                      [
                        ( "packageTwo"
                        , PkgLockDependency
                            { depVersion = "2.0.0"
                            , depDev = True
                            , depResolved = NpmResolved $ Just "https://example.com/two.tgz"
                            , depRequires = Map.fromList [("packageThree", "3.0.0")]
                            , depDependencies = mempty
                            }
                        )
                      ]
                }
            )
          ,
            ( "packageThree"
            , PkgLockDependency
                { depVersion = "3.0.0"
                , depDev = True
                , depResolved = NpmResolved $ Just "https://example.com/three.tgz"
                , depRequires = Map.fromList [("packageOne", "1.0.0")]
                , depDependencies = mempty
                }
            )
          ,
            ( "packageSeven"
            , PkgLockDependency
                { depVersion = "7.0.0"
                , depDev = False
                , depResolved = NpmResolved $ Just "https://example.com/seven.tgz"
                , depRequires = mempty
                , depDependencies = mempty
                }
            )
          ,
            ( "packageFour"
            , PkgLockDependency
                { depVersion = "file:abc/def"
                , depDev = False
                , depResolved = NpmResolved Nothing
                , depRequires = mempty
                , depDependencies = mempty
                }
            )
          ,
            ( "packageFive"
            , PkgLockDependency
                { depVersion = "5.0.0"
                , depDev = True
                , depResolved = NpmResolved $ Just "https://example.com/five.tgz"
                , depRequires = Map.fromList [("packageSix", "6.0.0")]
                , depDependencies = mempty
                }
            )
          ,
            ( "packageSix"
            , PkgLockDependency
                { depVersion = "6.0.0"
                , depDev = True
                , depResolved = NpmResolved $ Just "https://example.com/six.tgz"
                , depRequires = mempty
                , depDependencies = mempty
                }
            )
          ]
    }

packageOne :: Dependency
packageOne =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "packageOne"
    , dependencyVersion = Just (CEq "1.0.0")
    , dependencyLocations = ["https://example.com/one.tgz"]
    , dependencyEnvironments = Set.fromList [EnvProduction, EnvDevelopment]
    , dependencyTags = Map.empty
    }

packageTwo :: Dependency
packageTwo =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "packageTwo"
    , dependencyVersion = Just (CEq "2.0.0")
    , dependencyLocations = ["https://example.com/two.tgz"]
    , dependencyEnvironments = Set.singleton EnvDevelopment
    , dependencyTags = Map.empty
    }

packageThree :: Dependency
packageThree =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "packageThree"
    , dependencyVersion = Just (CEq "3.0.0")
    , dependencyLocations = ["https://example.com/three.tgz"]
    , dependencyEnvironments = Set.singleton EnvDevelopment
    , dependencyTags = Map.empty
    }

packageFive :: Dependency
packageFive =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "packageFive"
    , dependencyVersion = Just (CEq "5.0.0")
    , dependencyLocations = ["https://example.com/five.tgz"]
    , dependencyEnvironments = Set.singleton EnvDevelopment
    , dependencyTags = Map.empty
    }

packageSix :: Dependency
packageSix =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "packageSix"
    , dependencyVersion = Just (CEq "6.0.0")
    , dependencyLocations = ["https://example.com/six.tgz"]
    , dependencyEnvironments = Set.singleton EnvDevelopment
    , dependencyTags = Map.empty
    }

packageSeven :: Dependency
packageSeven =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "packageSeven"
    , dependencyVersion = Just (CEq "7.0.0")
    , dependencyLocations = ["https://example.com/seven.tgz"]
    , dependencyEnvironments = Set.singleton EnvProduction
    , dependencyTags = Map.empty
    }

argparseDirect :: Dependency
argparseDirect =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "argparse"
    , dependencyVersion = Just $ CEq "1.0.10"
    , dependencyLocations = ["https://registry.npmjs.org/argparse/-/argparse-1.0.10.tgz"]
    , dependencyEnvironments = Set.singleton EnvProduction
    , dependencyTags = mempty
    }

argparseDeep :: Dependency
argparseDeep =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "argparse"
    , dependencyVersion = Just $ CEq "2.0.1"
    , dependencyLocations = ["https://registry.npmjs.org/argparse/-/argparse-2.0.1.tgz"]
    , dependencyEnvironments = Set.singleton EnvProduction
    , dependencyTags = mempty
    }

jsyaml :: Dependency
jsyaml =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "js-yaml"
    , dependencyVersion = Just $ CEq "4.1.0"
    , dependencyLocations = ["https://registry.npmjs.org/js-yaml/-/js-yaml-4.1.0.tgz"]
    , dependencyEnvironments = Set.singleton EnvProduction
    , dependencyTags = mempty
    }

sprintf :: Dependency
sprintf =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "sprintf-js"
    , dependencyVersion = Just $ CEq "1.0.3"
    , dependencyLocations = ["https://registry.npmjs.org/sprintf-js/-/sprintf-js-1.0.3.tgz"]
    , dependencyEnvironments = Set.singleton EnvProduction
    , dependencyTags = mempty
    }

async :: Dependency
async =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "async"
    , dependencyVersion = Just $ CEq "3.2.3"
    , dependencyLocations = ["https://registry.npmjs.org/async/-/async-3.2.3.tgz"]
    , dependencyEnvironments = Set.singleton EnvProduction
    , dependencyTags = mempty
    }

mustache :: Dependency
mustache =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "mustache"
    , dependencyVersion = Just $ CEq "2.3.2"
    , dependencyLocations = ["https://registry.npmjs.org/mustache/-/mustache-2.3.2.tgz"]
    , dependencyEnvironments = Set.singleton EnvProduction
    , dependencyTags = mempty
    }

winston :: Dependency
winston =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "winston"
    , dependencyVersion = Just $ CEq "3.6.0"
    , dependencyLocations = ["https://registry.npmjs.org/winston/-/winston-3.6.0.tgz"]
    , dependencyEnvironments = Set.singleton EnvProduction
    , dependencyTags = mempty
    }

winstonMail :: Dependency
winstonMail =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "winston-mail"
    , dependencyVersion = Just $ CEq "2.0.0"
    , dependencyLocations = ["https://registry.npmjs.org/winston-mail/-/winston-mail-2.0.0.tgz"]
    , dependencyEnvironments = Set.singleton EnvProduction
    , dependencyTags = mempty
    }

underscore :: Dependency
underscore =
  Dependency
    { dependencyType = NodeJSType
    , dependencyName = "underscore"
    , dependencyVersion = Just $ CEq "1.13.2"
    , dependencyLocations = ["https://registry.npmjs.org/underscore/-/underscore-1.13.2.tgz"]
    , dependencyEnvironments = Set.singleton EnvProduction
    , dependencyTags = mempty
    }

buildGraphSpec :: Path Abs Dir -> Spec
buildGraphSpec testDir =
  describe "buildGraph" $ do
    it "should produce expected output" $ do
      let graph = buildGraph mockInput (Set.fromList ["packageOne", "packageThree", "packageFive"])
      expectDeps [packageOne, packageTwo, packageThree, packageFive, packageSix, packageSeven] graph
      expectDirect [packageOne, packageThree, packageFive] graph
      expectEdges
        [ (packageOne, packageTwo)
        , (packageOne, packageSeven)
        , (packageTwo, packageThree)
        , (packageThree, packageOne)
        , (packageFive, packageSix)
        ]
        graph

    it' "should process nested dependencies" $ do
      parsed <- readContentsJson (testDir </> $(mkRelFile "nested-deps.json"))
      let graph = buildGraph parsed (Set.fromList ["argparse", "js-yaml", "sprintf-js"])
      expectDeps' [argparseDeep, argparseDirect, jsyaml, sprintf] graph
      expectDirect' [argparseDirect, jsyaml, sprintf] graph
      expectEdges'
        [ (jsyaml, argparseDeep)
        , (argparseDirect, sprintf)
        ]
        graph

    it' "Should process peer dependencies" $ do
      -- I stripped this file down manually to have a smaller example to test
      -- `npm` would generate a much more complicated package-lock.json
      parsed <- readContentsJson $ testDir </> $(mkRelFile "peerdeps-package-json.lock")
      -- Top-level peerDependencies are treated just like direct
      -- dependencies. For this test "winston-mail" is a top-level peer
      -- dependency and "underscore" is a regular top-level dependency.
      let graph = buildGraph parsed (Set.fromList ["winston-mail", "underscore"])
      expectDeps' [async, mustache, winston, winstonMail, underscore] graph
      expectDirect' [winstonMail, underscore] graph
      expectEdges'
        [ (winstonMail, mustache)
        , (winstonMail, winston)
        , (winston, async)
        ]
        graph

    it "label required deps as 'EnvDevelopment' if the parent is dev" $ do
      let graph = buildGraph mockRequiredMissingDep (Set.singleton "packageThree")
      expectDep mockDevRequireMissingDependency graph

    it "Should process namespaced peer dependencies" $ do
      let graph = buildGraph mockNameSpacedPeerDepLock Set.empty
      expectEdges [(mockNSPeerDepPackageOne, mockNSPeerDepPackageTwo)] graph

packageLockParseSpec :: Path Abs Dir -> Spec
packageLockParseSpec testDir =
  describe "parsing package-json.lock" $ do
    it' "Should ignore \"resolved\": <bool> in package-lock.json" $ do
      let packageLock = testDir </> $(mkRelFile "boolean-resolved-package-lock.json")
      PkgLockJson{lockDependencies = packageDependencies} <- readContentsJson packageLock
      let foo = unNpmResolved . depResolved =<< Map.lookup "foo" packageDependencies
      foo `shouldBe'` Nothing

    it' "Should parse \"resolved\": <string> in package-lock.json" $ do
      let packageLock = testDir </> $(mkRelFile "string-resolved-package-lock.json")
      PkgLockJson{lockDependencies = packageDependencies} <- readContentsJson packageLock
      let foo = unNpmResolved . depResolved =<< Map.lookup "foo" packageDependencies
      foo `shouldBe'` Just "https://bar.npmjs.org/foo/-/foo-1.0.0.tgz"

    it' "Should parse dependency with no \"resolved\" key in package-lock.json" $ do
      let packageLock = testDir </> $(mkRelFile "absent-resolved-package-lock.json")
      PkgLockJson{lockDependencies = packageDependencies} <- readContentsJson packageLock
      let foo = unNpmResolved . depResolved =<< Map.lookup "foo" packageDependencies
      foo `shouldBe'` Nothing

spec :: Spec
spec = do
  curdir <- runIO getCurrentDir
  let testDir = curdir </> $(mkRelDir "test/Node/testdata")

  buildGraphSpec testDir
  packageLockParseSpec testDir

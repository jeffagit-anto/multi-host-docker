{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import           Control.Concurrent           (threadDelay)
import           Control.Concurrent.Async
import           Control.Exception            (catch, throw)
import           Control.Monad
import           Control.Monad.Trans.Free
import           Data.Either
import           Data.Functor.Sum
import           Data.List                    (intercalate, intersperse,
                                               isSuffixOf)
import           Data.Maybe
import           Network.DO.Commands
import           Network.DO.Droplets.Commands
import           Network.DO.Droplets.Utils
import           Network.DO.Net
import           Network.DO.Pairing
import           Network.DO.Types
import           Network.REST
import           Propellor                    hiding (Sum, Result, createProcess)
import           Propellor.Utilities          (shellWrap)
import           System.Build
import           System.Docker
import           System.Environment
import           System.Exit
import           System.IO
import           System.IO.Error              (isDoesNotExistError)
import           System.IO.Extra              (copy)
import           System.Process               (CreateProcess (..),
                                               StdStream (..), callProcess,
                                               createProcess, proc, readProcess)
import           Types

main :: IO ()
main = do
  action <- options
  go action

  where
    go (CreateDroplets num userKey compile deploy exe srcDir imageName) = do
      when compile $ void $ buildInDocker srcDir exe imageName
      hosts <- createHostsOnDO userKey num
      when (not $ null $ lefts hosts) $ putStrLn ("Hosts creation failed: " ++ show hosts ) >> exitWith (ExitFailure 1)
      when deploy $ void $ configureHosts (rights hosts)

      print hosts
    go (RunPropellor allHosts exe h) = void $ runPropellor allHosts exe h
    go (BuildPropellor src tgt imageName) = void $ buildInDocker src tgt imageName
    go BuildOpenVSwitch = void $ buildOpenVSwitch

createHostsOnDO :: Int -> Int -> IO [ Result Droplet ]
createHostsOnDO userKey n = do
  putStrLn ("Creating " ++ show n ++ " hosts")
  mapConcurrently (createHostOnDO userKey) [ 1 .. n ]
  where
    createHostOnDO userKey num = do
      authToken <- getAuthFromEnv
      putStrLn $ "creating host " ++ show num ++ " with AUTH_KEY "++ show authToken
      let droplet = BoxConfiguration ("host" ++ show num) (RegionSlug "ams2") G1 defaultImage [userKey] False
      runWreq $ pairEffectM (\ _ b -> return b) (mkDOClient $ Tool Nothing authToken False) (injr (createDroplet droplet) :: FreeT (Sum DO DropletCommands) (RESTT IO) (Result Droplet))

    getAuthFromEnv :: IO (Maybe AuthToken)
    getAuthFromEnv = (Just `fmap` getEnv "AUTH_TOKEN") `catch` (\ (e :: IOError) -> if isDoesNotExistError e then return Nothing else throw e)

configureHosts :: [Droplet] -> IO [Droplet]
configureHosts droplets = do
  mapM (runPropellor hosts "propell") hosts
  return droplets
  where
    hosts      = configured droplets
    configured = map show . catMaybes . map publicIP

runPropellor :: [ HostName ] -> String -> HostName -> IO ()
runPropellor allHosts configExe h = do
  unlessM (trySsh h 10) $ fail $ "cannot ssh into host " ++ h ++ " after 10s"
  uploadOpenVSwitch ["openvswitch-common_2.3.1-1_amd64.deb",  "openvswitch-switch_2.3.1-1_amd64.deb"] h
  callProcess "scp" [ "-o","StrictHostKeyChecking=no", configExe, "root@" ++ h ++ ":" ]
  callProcess "ssh" [ "-o","StrictHostKeyChecking=no", "root@" ++ h, runRemotePropellCmd h ]
    where
      runRemotePropellCmd h = shellWrap $ intercalate " && " [ "chmod +x " ++ configExe
                                                             , "./" ++ configExe ++ " " ++ h ++ " " ++ allIps
                                                             ]
      allIps = concat $ intersperse " " allHosts

      trySsh :: HostName -> Int -> IO Bool
      trySsh h n = do
        res <- boolSystem "ssh" (map Param $ [ "-o","StrictHostKeyChecking=no", "root@" ++ h, "/bin/true" ])
        if (not res && n > 0)
          then do
            threadDelay 1000000
            trySsh h (n - 1)
          else return res

unlessM :: (Monad m) => m Bool -> m () -> m ()
unlessM test ifFail = do
  result <- test
  when (not result) $ ifFail

buildInDocker :: FilePath -> String -> String -> IO FilePath
buildInDocker srcDir targetName imageName = stackInDocker (ImageName imageName) srcDir targetName

buildOpenVSwitch :: IO [ FilePath ]
buildOpenVSwitch = do
  callProcess "docker" ["build", "-t", imageName, "openvswitch" ]
  debs <- filter (".deb" `isSuffixOf`) . lines <$> readProcess "docker" [ "run", "--rm", imageName, "ls",  "-1", "/" ] ""
  localDebs <- forM debs extractPackage
  return localDebs
    where
      imageName = "openvswitch:2.3.1"

      extractPackage deb = do
        (_, Just hout, _, phdl) <- createProcess  (proc "docker" [ "run", "--rm", imageName, "dd", "if=/" ++ deb ]) { std_out = CreatePipe }
        withBinaryFile deb WriteMode $ \ hDst -> copy hout hDst
        void $ waitForProcess phdl
        return deb

uploadOpenVSwitch :: [ FilePath ] -> String -> IO ()
uploadOpenVSwitch debs host = forM_ debs $ \ deb -> callProcess "scp" [ "-o","StrictHostKeyChecking=no", deb, "root@" ++ host ++ ":" ]


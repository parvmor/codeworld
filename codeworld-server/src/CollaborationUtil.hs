{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-
  Copyright 2017 The CodeWorld Authors. All rights reserved.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
-}

module CollaborationUtil where

import           Control.Monad
import           Data.Aeson
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as LB
import           Data.Text (Text)
import qualified Data.Text as T
import           System.Directory
import           System.FilePath

import CommentUtil
import DataUtil
import Model

newtype CollabId = CollabId { unCollabId :: Text } deriving (Eq)

collabHashRootDir :: BuildMode -> FilePath
collabHashRootDir (BuildMode m) = "data" </> m </> "projectContents"

nameToCollabHash :: FilePath -> CollabId
nameToCollabHash = CollabId . hashToId "H" . BC.pack

ensureCollabHashDir :: BuildMode -> CollabId -> IO ()
ensureCollabHashDir mode (CollabId c) = createDirectoryIfMissing True dir
  where dir = collabHashRootDir mode </> take 3 (T.unpack c)

collabHashLink :: CollabId -> FilePath
collabHashLink (CollabId c) = let s = T.unpack c in take 3 s </> s

newCollaboratedProject :: BuildMode -> Text -> Text -> ByteString -> FilePath -> Project -> IO (Either String ())
newCollaboratedProject mode userId' userIdent' name projectFilePath project = do
    let collabHash = nameToCollabHash projectFilePath
        collabHashPath = collabHashRootDir mode </> collabHashLink collabHash <.> "cw"
        userDump = UserDump userId' userIdent' (T.pack projectFilePath) "owner"
        identAllowed = foldl (\acc l -> if l `elem` (T.unpack userIdent')
                                        then False else acc) True ['/', '.', '+']
    case identAllowed of
        False -> return $ Left "User Identifier Has Unallowed Characters(/+.)"
        True -> do
            ensureCollabHashDir mode collabHash
            B.writeFile collabHashPath $ LB.toStrict . encode $ project
            B.writeFile (collabHashPath <.> "users") $
              LB.toStrict . encode $ userDump : []
            B.writeFile projectFilePath $ BC.pack collabHashPath
            B.writeFile (projectFilePath <.> "info") name
            addCommentFunc mode userDump project $ collabHashPath <.> "comments"
            return $ Right ()

addForCollaboration :: BuildMode -> Text -> Text -> ByteString -> FilePath -> FilePath -> IO (Either String ())
addForCollaboration mode userId' userIdent' name projectFilePath collabFilePath = do
    let userDump = UserDump userId' userIdent' (T.pack projectFilePath) "owner"
        identAllowed = foldl (\acc l -> if l `elem` (T.unpack userIdent')
                                        then False else acc) True ['/', '.', '+']
    case identAllowed of
        False -> return $ Left "User Identifier Has Unallowed Characters(/+.)"
        True -> do
            Just (currentUsers :: [UserDump]) <- decodeStrict <$>
              B.readFile (collabFilePath <.> "users")
            let currentIdents = map uuserIdent currentUsers
                currentIds = map uuserId currentUsers
            case (userId' `elem` currentIds, userIdent' `elem` currentIdents) of
                (True, _) -> return $ Left "User already exists maybe with a different identifier"
                (False, True) -> return $ Left "User Identifier already exists"
                (False, False) -> do
                    res <- addNewOwner mode userDump $ collabFilePath <.> "comments"
                    case res of
                        Left err -> return $ Left err
                        Right _ -> do
                            B.writeFile (collabFilePath <.> "users") $
                              LB.toStrict . encode $ userDump : currentUsers
                            createDirectoryIfMissing False (takeDirectory projectFilePath)
                            B.writeFile projectFilePath $ BC.pack collabFilePath
                            B.writeFile (projectFilePath <.> "info") name
                            return $ Right ()

removeProjectIfExists :: BuildMode -> Text -> FilePath -> IO ()
removeProjectIfExists mode userId' userPath = do
    projectContentPath <- BC.unpack <$> B.readFile userPath
    _ <- removeUserFromCollaboration mode userId' projectContentPath
    removeFileIfExists userPath
    removeFileIfExists $ userPath <.> "info"
    cleanBaseDirectory userPath

removeUserFromCollaboration :: BuildMode -> Text -> FilePath -> IO (Either String ())
removeUserFromCollaboration mode userId' projectContentPath = do
    Just (currentUsers :: [UserDump]) <- decodeStrict <$>
      B.readFile (projectContentPath <.> "users")
    case userId' `elem` (map uuserId currentUsers) of
        False -> do
            return $ Left "User does not exists in the project which is being tried to be deleted"
        True -> do
            let newUsers = filter (\x -> uuserId x /= userId') currentUsers
            case length newUsers of
                0 -> do
                    removeCollaboratedProject projectContentPath
                    removeCommentUtils $ projectContentPath <.> "comments"
                    cleanBaseDirectory projectContentPath
                    cleanCommentHashPath mode userId' $ projectContentPath <.> "comments"
                _ -> do
                -- update hash path to one of existing users path since this users filepath may contain different project
                    B.writeFile (projectContentPath <.> "users") $
                      LB.toStrict . encode $ newUsers
                    removeOwnerPathInComments mode userId' $ projectContentPath <.> "comments"
                    modifyCollabPath mode projectContentPath
            return $ Right ()

modifyCollabPath :: BuildMode -> FilePath -> IO ()
modifyCollabPath mode projectContentPath = do
    Just (currentUsers :: [UserDump]) <- decodeStrict <$>
      B.readFile (projectContentPath <.> "users")
    let newCollabHash = nameToCollabHash . T.unpack . upath $ currentUsers !! 0
        newCollabHashPath = collabHashRootDir mode </> collabHashLink newCollabHash <.> "cw"
    forM_ currentUsers $ \u -> do
        B.writeFile (T.unpack $ upath u) $ BC.pack newCollabHashPath
    createDirectoryIfMissing False $ takeDirectory newCollabHashPath
    mapM_ (\x -> renameDirectory (projectContentPath <.> x) $ newCollabHashPath <.> x)
      ["comments", "comments" <.> "users", "comments" <.> "versions"]
    mapM_ (\x -> renameFile (projectContentPath <.> x) $ newCollabHashPath <.> x)
      ["", "users"]
    cleanBaseDirectory projectContentPath
    updateSharedCommentPath mode (projectContentPath <.> "comments") $ newCollabHashPath <.> "comments"

modifyCollabPathIfReq :: BuildMode -> Text -> FilePath -> FilePath -> IO ()
modifyCollabPathIfReq mode userId' fromFile toFile = do
    let collabHash = nameToCollabHash fromFile
        collabHashPath = collabHashRootDir mode </> collabHashLink collabHash <.> "cw"
    projectContentPath <- BC.unpack <$> B.readFile toFile
    Just (currentUsers :: [UserDump]) <- decodeStrict <$>
      B.readFile (projectContentPath <.> "users")
    B.writeFile (projectContentPath <.> "users") $
      LB.toStrict . encode $ map (\x -> if userId' == uuserId x
                                            then x { upath = T.pack toFile }
                                            else x) currentUsers
    correctOwnerPathInComments mode userId' toFile $ projectContentPath <.> "comments"
    case projectContentPath == collabHashPath of
        True -> modifyCollabPath mode projectContentPath
        False -> return ()

removeCommentUtils :: FilePath -> IO ()
removeCommentUtils commentFolder = do
    mapM_ (\x -> removeDirectoryIfExists $ commentFolder <.> x) ["", "users", "versions"]

removeCollaboratedProject :: FilePath -> IO ()
removeCollaboratedProject projectContentPath = do
    removeFileIfExists projectContentPath
    removeFileIfExists $ projectContentPath <.> "users"
    cleanBaseDirectory projectContentPath

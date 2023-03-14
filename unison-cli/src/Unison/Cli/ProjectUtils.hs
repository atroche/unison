-- | Project-related utilities.
module Unison.Cli.ProjectUtils
  ( getCurrentProjectBranch,
    projectPath,
    projectBranchPath,

    -- * Name resolution
    resolveNames,
    resolveNamesToIds,

    -- ** Path prisms
    projectBranchPathPrism,

    -- ** Project/Branch names
    expectResolveRemoteProjectName,
    expectResolveRemoteProjectBranchName,

    -- ** Temp
    loggeth,
  )
where

import Control.Lens
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.These (These (..))
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import U.Codebase.Sqlite.DbId
import qualified U.Codebase.Sqlite.Queries as Queries
import Unison.Cli.Monad (Cli)
import qualified Unison.Cli.Monad as Cli
import qualified Unison.Cli.MonadUtils as Cli
import qualified Unison.Cli.Share.Projects as Share
import Unison.Codebase.Editor.Output (Output (LocalProjectBranchDoesntExist))
import qualified Unison.Codebase.Path as Path
import Unison.NameSegment (NameSegment (..))
import Unison.Prelude
import Unison.Project (ProjectAndBranch (..), ProjectBranchName, ProjectName)
import Witch (unsafeFrom)

-- | Get the current project+branch that a user is on.
--
-- Note that if a user has (somehow) cd'd into a namespace *within* a branch, this function will return Nothing; that
-- is, it only returns Just if the user's current namespace is the root of a branch, and no deeper.
--
-- This should be fine: we don't want users to be able to cd around willy-nilly within projects (right?...)
getCurrentProjectBranch :: Cli (Maybe (ProjectAndBranch ProjectId ProjectBranchId))
getCurrentProjectBranch = do
  path <- Cli.getCurrentPath
  pure (preview projectBranchPathPrism path)

-- Resolve a "these names" to a "both names", using the following defaults if a name is missing:
--
--   * The project at the current path
--   * The branch named "main"
resolveNames :: These ProjectName ProjectBranchName -> Cli (ProjectAndBranch ProjectName ProjectBranchName)
resolveNames = \case
  This projectName -> pure (ProjectAndBranch projectName (unsafeFrom @Text "main"))
  That branchName -> do
    ProjectAndBranch projectId _branchId <-
      getCurrentProjectBranch & onNothingM do
        loggeth ["not on a project branch"]
        Cli.returnEarlyWithoutOutput
    Cli.runTransaction do
      project <- Queries.expectProject projectId
      pure (ProjectAndBranch (project ^. #name) branchName)
  These projectName branchName -> pure (ProjectAndBranch projectName branchName)

expectResolveRemoteProjectName :: ProjectName -> Cli Share.RemoteProject
expectResolveRemoteProjectName remoteProjectName = do
  Share.getProjectByName remoteProjectName & onNothingM do
    loggeth ["remote project doesn't exist"]
    Cli.returnEarlyWithoutOutput

expectResolveRemoteProjectBranchName :: RemoteProjectId -> ProjectBranchName -> Cli Share.RemoteProjectBranch
expectResolveRemoteProjectBranchName remoteProjectId branchName = do
  resolveRemoteProjectBranchName remoteProjectId branchName >>= \case
    Nothing -> do
      loggeth ["branch doesn't exist: ", tShow branchName]
      Cli.returnEarlyWithoutOutput
    Just x -> pure x

resolveRemoteProjectBranchName :: RemoteProjectId -> ProjectBranchName -> Cli (Maybe Share.RemoteProjectBranch)
resolveRemoteProjectBranchName remoteProjectId remoteProjectBranchName = do
  Share.getProjectBranchByName (ProjectAndBranch remoteProjectId remoteProjectBranchName) >>= \case
    Share.GetProjectBranchResponseBranchNotFound -> pure Nothing
    Share.GetProjectBranchResponseProjectNotFound -> do
      -- todo: mark remote project as deleted
      pure Nothing
    Share.GetProjectBranchResponseSuccess remoteBranch -> pure (Just remoteBranch)

-- Like 'resolveNames', but resolves to project and branch ids.
resolveNamesToIds :: These ProjectName ProjectBranchName -> Cli (ProjectAndBranch ProjectId ProjectBranchId)
resolveNamesToIds = \case
  This projectName -> resolveNamesToIds (These projectName (unsafeFrom @Text "main"))
  That branchName -> do
    ProjectAndBranch projectId _branchId <-
      getCurrentProjectBranch & onNothingM do
        loggeth ["not on a project branch yo"]
        Cli.returnEarlyWithoutOutput
    branch <-
      Cli.runTransaction (Queries.loadProjectBranchByName projectId branchName) & onNothingM do
        project <- Cli.runTransaction (Queries.expectProject projectId)
        Cli.returnEarly (LocalProjectBranchDoesntExist (ProjectAndBranch (project ^. #name) branchName))
    pure (ProjectAndBranch projectId (branch ^. #branchId))
  These projectName branchName -> do
    maybeProjectAndBranch <-
      Cli.runTransaction do
        runMaybeT do
          project <- MaybeT (Queries.loadProjectByName projectName)
          let projectId = project ^. #projectId
          branch <- MaybeT (Queries.loadProjectBranchByName projectId branchName)
          pure (ProjectAndBranch projectId (branch ^. #branchId))
    maybeProjectAndBranch & onNothing do
      Cli.returnEarly (LocalProjectBranchDoesntExist (ProjectAndBranch projectName branchName))

-- | Get the path that a project is stored at. Users aren't supposed to go here.
--
-- >>> projectPath "ABCD"
-- .__projects._ABCD
projectPath :: ProjectId -> Path.Absolute
projectPath projectId =
  review projectPathPrism projectId

-- | Get the path that a branch is stored at. Users aren't supposed to go here.
--
-- >>> projectBranchPath ProjectAndBranch { project = "ABCD", branch = "DEFG" }
-- .__projects._ABCD.branches._DEFG
projectBranchPath :: ProjectAndBranch ProjectId ProjectBranchId -> Path.Absolute
projectBranchPath =
  review projectBranchPathPrism

------------------------------------------------------------------------------------------------------------------------

pattern UUIDNameSegment :: UUID -> NameSegment
pattern UUIDNameSegment uuid <-
  NameSegment (Text.uncons -> Just ('_', UUID.fromText . Text.map (\c -> if c == '_' then '-' else c) -> Just uuid))
  where
    UUIDNameSegment uuid = NameSegment (Text.cons '_' (Text.map (\c -> if c == '-' then '_' else c) (UUID.toText uuid)))

-- | The prism between paths like
--
-- @
-- .__projects._XX_XX
-- @
--
-- and the project id
--
-- @
-- XX-XX
-- @
projectPathPrism :: Prism' Path.Absolute ProjectId
projectPathPrism =
  prism' toPath toId
  where
    toPath :: ProjectId -> Path.Absolute
    toPath projectId =
      Path.Absolute $
        Path.fromList
          [ "__projects",
            UUIDNameSegment (unProjectId projectId)
          ]

    toId :: Path.Absolute -> Maybe ProjectId
    toId path =
      case Path.toList (Path.unabsolute path) of
        ["__projects", UUIDNameSegment projectId] -> Just (ProjectId projectId)
        _ -> Nothing

-- | The prism between paths like
--
-- @
-- .__projects._XX_XX.branches._YY_YY
-- @
--
-- and the @(project id, branch id)@ pair
--
-- @
-- (XX-XX, YY-YY)
-- @
projectBranchPathPrism :: Prism' Path.Absolute (ProjectAndBranch ProjectId ProjectBranchId)
projectBranchPathPrism =
  prism' toPath toIds
  where
    toPath :: ProjectAndBranch ProjectId ProjectBranchId -> Path.Absolute
    toPath ProjectAndBranch {project = projectId, branch = branchId} =
      Path.Absolute $
        Path.fromList
          [ "__projects",
            UUIDNameSegment (unProjectId projectId),
            "branches",
            UUIDNameSegment (unProjectBranchId branchId)
          ]

    toIds :: Path.Absolute -> Maybe (ProjectAndBranch ProjectId ProjectBranchId)
    toIds path =
      case Path.toList (Path.unabsolute path) of
        ["__projects", UUIDNameSegment projectId, "branches", UUIDNameSegment branchId] ->
          Just ProjectAndBranch {project = ProjectId projectId, branch = ProjectBranchId branchId}
        _ -> Nothing

-- Dumb temporary debug logger to use for the new project commands
loggeth :: [Text] -> Cli ()
loggeth =
  liftIO . Text.putStrLn . Text.concat . ("[coolbeans] " :)

{-# LANGUAGE RecordWildCards, TupleSections, OverloadedStrings #-}
module Logic.Game where

import           Prelude hiding (and, or, foldl, foldr)
import           Data.Array
import           Data.Aeson hiding (Array)
import           Data.Attoparsec.Number
import           Data.Maybe
import           Data.Foldable
import           Data.Function (on)
import           Control.Monad
import           Data.Serialize (Serialize (..))
import           Data.Serialize.Get
import           Data.Serialize.Put
import           Data.Int
import           Data.Word8
import qualified Data.Map as Map
import           Data.List as L hiding (and, or, foldl, foldr, find)
import           Control.Applicative
import           Control.Monad.Random
import           Control.Monad.Trans.State (runStateT)
import           Control.Monad.State.Class (MonadState, gets, modify)
import           Yesod (PathPiece (..))
import qualified Data.Text as T hiding (find, zip, map)

-------------------------------------------------------------------------------
-- * AI
-------------------------------------------------------------------------------

-- | Operations an artificial intelligence has to provide for playing this game.
class AI a where
  -- | Initial state and fleet position
  aiInit
    :: MonadRandom m 
    => Rules                 -- ^ game rules
    -> m (a, FleetPlacement) -- ^ initial state

  -- | Computes the next shot based on the current AI state
  aiFire
    :: (MonadRandom m, MonadState a m) 
    => m Pos

  -- | Feedback to `aiFire`
  aiResponse
    :: (MonadRandom m, MonadState a m) 
    => Pos         -- ^ target position
    -> HitResponse -- ^ result of the last shot
    -> m ()

  -- | Computes the ship movement
  aiMove
    :: (MonadRandom m, MonadState a m)
    => Fleet                        -- ^ AI's fleet including IDs
    -> TrackingList                 -- ^ enemy shots
    -> m (Maybe (ShipID, Movement)) -- ^ ship and movement, if any
  aiMove _ _ = return Nothing

-------------------------------------------------------------------------------
-- * Game State
-------------------------------------------------------------------------------

data Rules = Rules
  { rulesSize         :: (Int, Int)
  , rulesShips        :: [Int]
  , rulesSafetyMargin :: Int
  , rulesAgainWhenHit :: Bool
  , rulesMove         :: Bool
  , rulesDevMode      :: Bool
  , rulesMaximumTurns :: Int
  } deriving (Show, Eq)

-- | Reponse sent to the AI after a shot.
data HitResponse
  = Water -- ^ the shot hit the water
  | Hit   -- ^ the shot hit a ship
  | Sunk  -- ^ the shot hit the last intact part of a ship
  deriving (Show, Eq, Ord, Bounded, Enum)

data Orientation 
  = Horizontal
  | Vertical
  deriving (Show, Eq, Ord, Bounded, Enum)

-- | Encodes a ships state using position, size and orientation
data ShipShape = ShipShape 
  { shipPosition    :: Pos
  , shipSize        :: Int
  , shipOrientation :: Orientation
  } deriving (Show, Eq)

-- | A ship using with unique id, a shape and current damage.
data Ship = Ship
  { shipID     :: ShipID         -- ^ unique ID of ship
  , shipShape  :: ShipShape      -- ^ shape of ship (including position, orientation and size)
  , shipDamage :: Array Int Bool -- ^ damage at each position
  } deriving (Show)

instance Eq Ship where
  (==) = (==) `on` shipID

-- | Used to allow lookup functions to work both with FleetPlacement and Fleet
class HasShipShape a where
  getShipShape :: a -> ShipShape
instance HasShipShape Ship where
  getShipShape = shipShape
instance HasShipShape ShipShape where
  getShipShape = id


-- | State of the game for both players.
data GameState a = GameState
  { currentPlayer  :: PlayerState -- ^ the current player's state 
  , otherPlayer    :: PlayerState -- ^ the other player's state
  , aiState        :: a           -- ^ state of the AI
  , gameRules      :: Rules
  , expectedAction :: Action
  , turnNumber     :: Int
  }

-- | The state belonging to one player
data PlayerState = PlayerState
  { playerShots :: TrackingList -- ^ the player's shots
  , playerFleet :: Fleet        -- ^ the player's fleet
  , playerType  :: Player
  } deriving (Show, Eq)

-- | type to distinguish between human and AI player
data Player
  = HumanPlayer
  | AIPlayer
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | the next action expected from the human player
data Action
  = ActionFire
  | ActionMove
  deriving (Show, Read, Eq, Ord, Enum, Bounded)

-- | keeps track of all relevant information for a fired shot
data Shot = Shot
  { shotPos    :: Pos
  , shotResult :: HitResponse
  , shotTime   :: Int
  } deriving (Show, Eq)

instance PathPiece Action where
  fromPathPiece "ActionFire" = Just ActionFire
  fromPathPiece "ActionMove" = Just ActionMove
  fromPathPiece  _ = Nothing
  toPathPiece = T.pack . show

-- | A fleet is a map of ship ID's to ships
type Fleet = Map.Map ShipID Ship

-- | A fleet placement is a list of the ship shapes
type FleetPlacement = [ShipShape]

-- | A two-dimensional position stored with zero-based indices
type Pos = (Int,Int)

-- | A grid is an array indexed by positions with zero-based indices
type Grid a = Array Pos a

-- | A list of all shots. Easier to handle, because no index lookup is needed.
type TrackingList = [Shot]

-- | Used for identifying a ship.
type ShipID = Int

-------------------------------------------------------------------------------
-- * New Games
-------------------------------------------------------------------------------

-- | Creates a new game.
newGame
  :: (AI a, MonadRandom m)
  => Rules          -- ^ rules of the game
  -> FleetPlacement -- ^ fleet of the human player
  -> Player         -- ^ beginning player
  -> m (GameState a)
newGame r pFleet begin = do 
  (ai, eFleet) <- aiInit r
  let
    humanPlayer = PlayerState [] (generateFleet pFleet) HumanPlayer
    aiPlayer    = PlayerState [] (generateFleet eFleet) AIPlayer
    template    = GameState
      { currentPlayer  = undefined
      , otherPlayer    = undefined
      , aiState        = ai
      , gameRules      = r
      , expectedAction = ActionFire -- the human is expected to fire a shot
      , turnNumber     = 0
      }
    gameState = case begin of
      HumanPlayer -> template { currentPlayer = humanPlayer, otherPlayer = aiPlayer }
      AIPlayer    -> template { currentPlayer = aiPlayer, otherPlayer = humanPlayer }
  return gameState

-- | The battleship default rules
defaultRules :: Rules 
defaultRules = Rules
  { rulesSize  = (10, 10)
  , rulesShips = [ 5, 4, 4, 3, 3, 3, 2, 2, 2, 2 ]
  , rulesSafetyMargin = 1
  , rulesAgainWhenHit = True
  , rulesMove  = True
  , rulesDevMode = False
  , rulesMaximumTurns = maxBound
  }

-- | Helper: Creates a grid, filled with one value.
newGrid :: (Int, Int) -> a -> Grid a
newGrid (w, h) a
  = array ((0, 0), (w - 1, h - 1))
    [((x, y), a) | x <- [0 .. w - 1], y <- [0 .. h - 1]]

-------------------------------------------------------------------------------
-- * Helper Functions
-------------------------------------------------------------------------------

gridSize :: Grid a -> (Int, Int)
gridSize grid = let ((x1,y1),(x2,y2)) = bounds grid in (x2 - x1 + 1, y2 - y1 + 1)

shipAdmissible :: Rules -> FleetPlacement -> ShipShape -> Bool
shipAdmissible (Rules {..}) fleet ship = rangeCheck && freeCheck where
  -- check if ship is completely inside grid
  rangeCheck     = L.all (inRange gridRange)
                 $ shipCoordinates 0 ship
  -- check if ship is not overlapping the safety margin of other ships
  freeCheck      = L.all (isNothing . shipAt fleet)
                 $ shipCoordinates rulesSafetyMargin ship
  (w, h)         = rulesSize
  gridRange      = ((0, 0), (w - 1, h - 1))

-- | Calculates the position occupied by a ship including safety margin.
shipCoordinates :: HasShipShape s => Int -> s -> [Pos]
shipCoordinates margin (getShipShape -> ShipShape{..}) = 
  case shipOrientation of
    Horizontal -> [(x + i, y + d) | i <- [-margin..shipSize - 1 + margin], d <- [-margin..margin]]
    Vertical   -> [(x + d, y + i) | i <- [-margin..shipSize - 1 + margin], d <- [-margin..margin]]
  where (x, y) = shipPosition

shipAt :: (Foldable f, HasShipShape s) => f s -> Pos -> Maybe s
shipAt fleet (px, py) = find containsP fleet where
  containsP (getShipShape -> ShipShape{..}) = case shipOrientation of
    Horizontal -> px >= sx && px < sx + shipSize && py == sy
    Vertical   -> px == sx && py >= sy && py < sy + shipSize
    where (sx, sy) = shipPosition

-- | Returns the zero-based index of a ship cell based on a global coordinate
shipCellIndex :: HasShipShape s => Pos -> s -> Maybe Int
shipCellIndex (px,py) (getShipShape -> ShipShape{..}) = case shipOrientation of
    Horizontal 
      | px >= sx && px < sx + shipSize && py == sy -> Just $ px - sx
    Vertical
      | px == sx && py >= sy && py < sy + shipSize -> Just $ py - sy
    _ -> Nothing
    where (sx, sy) = shipPosition

-- | Inflicts damage to the specified ship cell
damageShip :: Int -> Ship -> Ship
damageShip i ship = ship { shipDamage = shipDamage ship // [(i,True)] }

allSunk :: Fleet -> Bool
allSunk = and . fmap isShipSunk

isDamaged :: Ship -> Bool
isDamaged = or . elems . shipDamage

isShipSunk :: Ship -> Bool
isShipSunk = and . elems . shipDamage

generateFleet :: FleetPlacement -> Fleet
generateFleet = Map.fromAscList . fmap newShip . zip [1..] where
  newShip (sID, shape) = (sID, Ship sID shape (listArray (0,shipSize shape-1) (repeat False)))

shipSizes :: Rules -> [Int]
shipSizes rules = sort $ nub (rulesShips rules)

numberShipsOfSize :: [Int] -> Int -> Int
numberShipsOfSize ships size = length $ filter (== size) ships

unsunkShips :: Fleet -> [Ship]
unsunkShips fleet = filter (not . isShipSunk) (Map.elems fleet)

sizesOfShips :: [Ship] -> [Int]
sizesOfShips = map (shipSize . shipShape)

-------------------------------------------------------------------------------
-- * Turn
-------------------------------------------------------------------------------

-- | Result of the turn with respect to the current player
data Turn = Won | Again | Next deriving (Show, Eq, Ord, Enum, Bounded)

-- | Performs a full AI turn. 
-- This function takes care of swapping the current player.
-- If the AI player won, the currentPlayer is not swapped back.
-- 1. according to the rules, the AI may fire once or more
-- 2. according to the rules, the AI may move one ship
aiTurn :: (MonadState (GameState a) m, MonadRandom m, AI a)
        => m Turn
aiTurn = do
    switchRoles
    result <- shots
    rules <- gets gameRules
    when (result /= Won && rulesMove rules) $ executeMove moveAI
    switchRoles
    return result
  where
    shots = do
      result <- executeShot aiShot
      rules <- gets gameRules
      case result of
        -- the AI player is allowed to shoot once more, when enabled
        Again
          | rulesAgainWhenHit rules -> shots
          | otherwise               -> return Next
        -- the AI player has either won or missed
        _     -> return result

-- | This function executes the fire-part of the human's turn
-- It updates the "expectedAction" field of the state appropriately
humanTurnFire :: (MonadState (GameState a) m)
        => Pos -> m Turn
humanTurnFire target = do
  -- assert, that the human is allowed to fire a shot
  ActionFire <- gets expectedAction
  -- setup common actions
  rules <- gets gameRules
  -- fire
  result <- executeShot $ fireAt target
  case result of
    -- human has won, no further action needed
    Won -> return Won
    -- expect a move of the human player first
    -- human may fire again
    Again
      -- expected move is still "fire"
      -- otherwise: firing again not allowed, proceeding to default case
      | rulesAgainWhenHit rules -> return Again
    _ -> do
      -- update the action to "move" if appropriate
      humanFleet <- gets $ playerFleet . currentPlayer
      when (rulesMove rules && anyShipMovable rules humanFleet) $
        modify (\gs -> gs { expectedAction = ActionMove})
      return Next


-- | The current player fires at the other player
-- Modifies the list of shots fired by the player and
-- inflicts damage to the other player's ship, if hit.
fireAt :: (MonadState (GameState a) m) 
       => Pos -> m HitResponse
fireAt pos = do
  self  <- gets currentPlayer
  other <- gets otherPlayer
  let remainingFleet = Map.filter (not . isShipSunk) (playerFleet other)
  result <- case shipAt remainingFleet pos of
    Nothing -> return Water
    Just ship -> do
      let
        -- inflict damage to the ship
        Just idx = shipCellIndex pos ship
        newShip  = damageShip idx ship
        -- replace ship
        newFleet = Map.insert (shipID ship) newShip (playerFleet other)
        other'   = other { playerFleet = newFleet }
      -- update other player
      modify (\gs -> gs { otherPlayer = other' })
      return $ if isShipSunk newShip
        then Sunk
        else Hit
  -- add this shot to history
  time <- gets turnNumber
  let self' = self { playerShots = Shot pos result time : playerShots self }
  modify (\gs -> gs{currentPlayer = self'})
  return result

-- | Performs the enemies turn
-- assumes, that the enemy is the currentPlayer
aiShot :: (MonadState (GameState a) m, MonadRandom m, AI a) => m HitResponse
aiShot = do
  -- let the AI decide where to shoot
  ai <- gets aiState
  (pos, s) <- runStateT aiFire ai
  -- fire shot
  result <- fireAt pos
  -- give feedback to the AI
  (_, s')  <- runStateT (aiResponse pos result) s
  -- save modified AI state
  modify (\g -> g{aiState = s'})
  return result

-- | Executes the supplied turn.
executeShot :: (MonadState (GameState a) m)
            => (m HitResponse) -> m Turn
executeShot turn = do
  result <- turn
  op <- gets otherPlayer
  case result of
    Water -> return Next
    Hit   -> return Again
    Sunk
      | allSunk $ playerFleet op -> return Won
      | otherwise                -> return Again


-- | Switches the roles of active and passive player.
-- Every time the roles are switched, the turn number is increased.
switchRoles :: (MonadState (GameState a) m) => m ()
switchRoles = do
  modify(\g -> g
    { currentPlayer = otherPlayer g
    , otherPlayer = currentPlayer g
    })
  increaseTurnNumber

-- | increases the turn number. This function is called by `switchRoles`
-- and is not meant to be called directly.
increaseTurnNumber :: (MonadState (GameState a) m) => m ()
increaseTurnNumber = modify $ \gs -> gs {turnNumber = turnNumber gs + 1}

-------------------------------------------------------------------------------
-- * Move a ship
-------------------------------------------------------------------------------

-- | A ships movement
data Movement 
  = Forward  -- ^ -1 for the respective coordinate
  | Backward -- ^ +1 for the respective coordinate
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | Tries to move the human player's ship if pos is one of its endings.
-- Assumes that the human player is the currentPlayer
moveHuman :: (MonadState (GameState a) m) 
     => Maybe Pos -> m (Maybe (ShipID, Movement))
moveHuman pos = do
  -- assert the human is really expected to move a ship
  ActionMove <- gets expectedAction
  -- change expected action
  modify (\gs -> gs { expectedAction = ActionFire } )
  -- return real move
  case pos of
    Nothing -> return Nothing
    Just p  -> desiredMove p `liftM` gets (playerFleet . currentPlayer)

-- | Lets the AI decide on a move
-- Assumes that the ai player is the currentPlayer
moveAI :: (MonadState (GameState a) m, MonadRandom m, AI a) 
     => m (Maybe (ShipID, Movement))
moveAI = do
  ai <- gets aiState
  fleet <- gets (playerFleet . currentPlayer)
  shots <- gets (playerShots . otherPlayer)
  (mov, s) <- runStateT (aiMove fleet shots) ai
  modify (\g -> g{aiState = s})
  return mov

-- | executes a move for the current player
executeMove :: (MonadState (GameState a) m, MonadRandom m, AI a) 
     => m (Maybe (ShipID, Movement)) -> m ()
executeMove moveAction = do
  move <- moveAction
  curPlayer <- gets currentPlayer
  rules <- gets gameRules
  let fleet = playerFleet curPlayer
  case move of
    Nothing               -> return ()
    Just (shipID, movement) -> case Map.lookup shipID fleet of
      Just ship -> when (not $ isDamaged ship) $ do
        let
          newFleet   = moveShip ship movement rules fleet
          curPlayer' = curPlayer { playerFleet = newFleet }
        modify (\gs -> gs { currentPlayer = curPlayer' })
      Nothing -> return ()

-- | Find out which ship the player wants to move into which direction.
desiredMove :: Pos -> Fleet -> Maybe (ShipID, Movement)
desiredMove pos fleet = do 
  Ship{..} <- shipAt remainingFleet pos
  let 
    (x,y) = shipPosition $ shipShape
    size  = shipSize shipShape
  case shipOrientation shipShape of
    Horizontal 
      | pos == (x, y)            -> Just (shipID, Forward)
      | pos == (x + size - 1, y) -> Just (shipID, Backward)
    Vertical
      | pos == (x, y)            -> Just (shipID, Forward)
      | pos == (x, y + size - 1) -> Just (shipID, Backward)
    _ -> Nothing
  where remainingFleet = Map.filter (not . isDamaged) fleet

-- | Only moves the ship if it complies with the given rules.
moveShip :: Ship -> Movement -> Rules -> Fleet -> Fleet
moveShip ship movement rules fleet = 
  if isMovable movement rules fleet ship
    then Map.adjust (\s -> s{shipShape = newShape}) (shipID ship) fleet
    else fleet
  where newShape = movedShipShape movement (shipShape ship)
-- | Checks whether a ship can be moved.
isMovable :: Movement -> Rules -> Fleet -> Ship -> Bool
isMovable movement rules fleet ship =
       shipAdmissible rules otherShips newShape
    && not (isDamaged ship) 
  where
    newShape = movedShipShape movement (shipShape ship)
    otherShips = map (shipShape . snd)
               . Map.toAscList
               . Map.filter (not . isShipSunk) -- this ship can move over sunk ships
               . Map.delete (shipID ship)
               $ fleet

-- | Returns whether any ship in the given fleet is movable.
anyShipMovable :: Rules -> Fleet -> Bool
anyShipMovable rules fleet = rulesMove rules 
    && (anyForward || anyBackward)
  where
    anyForward  = or $ fmap (isMovable Forward rules fleet) fleet
    anyBackward = or $ fmap (isMovable Backward rules fleet) fleet

-- | Ship after movement was made.
movedShipShape :: Movement -> ShipShape -> ShipShape
movedShipShape movement ship = case (shipOrientation ship, movement) of
  (Horizontal, Forward)  -> ship {shipPosition = (x - 1, y)}
  (Horizontal, Backward) -> ship {shipPosition = (x + 1, y)}
  (Vertical, Forward)    -> ship {shipPosition = (x, y - 1)}
  (Vertical, Backward)   -> ship {shipPosition = (x, y + 1)}
  where (x,y) = shipPosition ship

-------------------------------------------------------------------------------
-- * Serialization
-------------------------------------------------------------------------------

instance Serialize a => Serialize (GameState a) where
  get = GameState <$> get <*> get <*> get <*> get <*> get <*> get
  put GameState {..} = do
    put currentPlayer
    put otherPlayer
    put aiState
    put gameRules
    put expectedAction
    put turnNumber

instance Serialize PlayerState where
  get = PlayerState <$> get <*> get <*> get
  put PlayerState{..} = do
    put playerShots
    put playerFleet
    put playerType

instance Serialize Rules where
  get = Rules <$> get <*> get <*> get <*> get <*> get <*> get <*> get
  put Rules {..} = do
    put rulesSize
    put rulesShips
    put rulesSafetyMargin
    put rulesAgainWhenHit
    put rulesMove
    put rulesDevMode
    put rulesMaximumTurns

instance Serialize HitResponse where
  get = fromByte <$> get
  put = put . toByte

instance Serialize Orientation where
  get = fromByte <$> get
  put = put . toByte

instance Serialize Player where
  get = fromByte <$> get
  put = put . toByte

instance Serialize Action where
  get = fromByte <$> get
  put = put . toByte

instance Serialize ShipShape where
  get = ShipShape <$> fmap fromPos8 get <*> fmap fromIntegral getWord8 <*> get
  put ShipShape{..} = do
    put $ toPos8 shipPosition
    putWord8 $ fromIntegral shipSize
    put shipOrientation

instance Serialize Ship where
  get = Ship <$> fmap fromIntegral getWord8 <*> get <*> get
  put Ship{..} = do
    putWord8 (fromIntegral shipID)
    put shipShape
    put shipDamage

instance Serialize Shot where
  get = Shot <$> fmap fromPos8 get <*> get <*> fmap fromIntegral getWord16le
  put Shot{..} = do
    put (toPos8 shotPos)
    put shotResult
    putWord16le $ fromIntegral shotTime

toPos8 :: Pos -> (Word8, Word8)
toPos8 (x,y) = (fromIntegral x, fromIntegral y)
fromPos8 :: (Word8, Word8) -> Pos
fromPos8 (x,y) = (fromIntegral x, fromIntegral y)

toByte :: Enum a => a -> Int8
toByte = fromIntegral . fromEnum

fromByte :: Enum a => Int8 -> a
fromByte = toEnum . fromIntegral

-------------------------------------------------------------------------------
-- * Random
-------------------------------------------------------------------------------

instance Random Orientation where
  randomR (a, b) g = (toEnum r, g') where
    (r, g')        = randomR (fromEnum a, fromEnum b) g
  random g         = randomR (Horizontal, Vertical) g

instance Random Movement where
  randomR (a, b) g = (toEnum r, g') where
    (r, g')        = randomR (fromEnum a, fromEnum b) g
  random g         = randomR (Forward, Backward) g

-------------------------------------------------------------------------------
-- * JSON
-------------------------------------------------------------------------------

instance FromJSON ShipShape where
   parseJSON (Object v) = curry ShipShape <$>
                          v .: "X" <*>
                          v .: "Y" <*>
                          v .: "Size" <*>
                          v .: "Orientation"
   -- A non-Object value is of the wrong type, so fail.
   parseJSON _          = mzero

instance FromJSON Orientation where
  parseJSON (Number (I i)) = return $ toEnum $ fromIntegral i
  parseJSON (Number (D d)) = return $ toEnum $ floor d
  parseJSON _              = mzero

instance ToJSON Orientation where
  toJSON = Number . I . fromIntegral . fromEnum

instance ToJSON ShipShape where
  toJSON (ShipShape {..}) = object 
    [ "X"           .= fst shipPosition
    , "Y"           .= snd shipPosition
    , "Size"        .= shipSize
    , "Orientation" .= shipOrientation
    ]

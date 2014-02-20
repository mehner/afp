{-# LANGUAGE RecordWildCards #-}
module Logic.AIUtil where

import           Prelude
import           Logic.Game
import           Logic.Random
import           Data.Array
import           Data.List
import           Data.Function
import           Data.Maybe (isJust, listToMaybe)
import qualified Data.Map as Map
import           Control.Arrow
import           Control.Monad
import           Control.Monad.Trans
import           Control.Monad.Trans.List
import           Control.Monad.Random
import           Text.Printf

--------------------------------------------------------------------------------
-- * Data types
--------------------------------------------------------------------------------

type Score = Double
type ScoreGrid = Array Pos Score

-- | A grid where the results of shots are tracked.
type TrackingGrid = Grid (Maybe HitResponse)

--------------------------------------------------------------------------------
-- * Placing ships
--------------------------------------------------------------------------------

initShips :: MonadRandom m => Rules -> FleetPlacement -> m (Maybe FleetPlacement)
initShips r fleet = do
  let ships = rulesShips r \\ (fmap shipSize fleet)
  fleets <- runRandM $ runListT $ foldM (initShips' r) fleet ships
  return $ listToMaybe fleets

-- | returns a random fleet, if one exists
initShips'
  :: (MonadRandom m)
  => Rules
  -> FleetPlacement
  -> Int
  -> ListT m FleetPlacement

initShips' r fleet len = do
  let admissible = admissibleShips r fleet len
  shuffled  <- lift $ shuffleRandom admissible
  placement <- choose shuffled
  return $ placement : fleet

-- | calculates all possible placements for a ship of the given lengths
admissibleShips :: Rules -> FleetPlacement -> Int -> [ShipShape]
admissibleShips r@(Rules {..}) fleet len = do
  let (w, h) = boardSize
  x <- [0 .. w - 1]
  y <- [0 .. h - 1]
  o <- [Horizontal, Vertical]
  let ship = ShipShape (x, y) len o
  guard $ shipAdmissible r fleet ship
  return ship

--------------------------------------------------------------------------------
-- * Helper functions
--------------------------------------------------------------------------------

isHit :: Maybe HitResponse -> Bool
isHit (Just Hit) = True
isHit _          = False

isSunk :: Maybe HitResponse -> Bool
isSunk (Just Sunk) = True
isSunk _           = False

isWater :: Maybe HitResponse -> Bool
isWater (Just Water) = True
isWater _            = False

isHitOrSunk :: Maybe HitResponse -> Bool
isHitOrSunk h = isSunk h || isHit h

addMargin :: Int -> Pos -> [Pos]
addMargin margin (x,y) = [(x + dx, y + dy) | dx <- [-margin..margin], dy <- [-margin..margin]]

-- can't find this function in the standard libraries...
removeNth :: Int -> [a] -> [a]
removeNth n xs = let (ys,zs) = splitAt n xs in ys ++ (tail zs)

choose :: MonadPlus m => [a] -> m a
choose = msum . fmap return

fromBool :: Num a => Bool -> a
fromBool True  = 1
fromBool False = 0

-- | Maximum function for nonnegative numbers which handles empty lists.
maximum' :: (Ord a, Num a) => [a] -> a
maximum' [] = 0
maximum' xs = maximum xs

--------------------------------------------------------------------------------
-- * Array Utilities
--------------------------------------------------------------------------------

maximumIx :: (Ix i, Ord e) => Array i e -> i
maximumIx = fst . maximumBy (compare `on` snd) . assocs

traverseArray :: (Ix i, Monad m) => (a -> m b) -> Array i a -> m (Array i b)
traverseArray f a = liftM (listArray (bounds a)) $ mapM f $ elems a

buildArray :: Ix i => (i, i) -> (i -> a) -> Array i a
buildArray bs f = array bs $ fmap (id &&& f) $ range bs

--------------------------------------------------------------------------------
-- * Debugging
--------------------------------------------------------------------------------

showPositions :: Int -> Int -> [Pos] -> String
showPositions width height ps = concat
  [(if (x,y) `elem` ps then "X" else " ")
  ++ (if x == width - 1 then "\n" else "")
  | y <- [0..height - 1]
  , x <- [0..width - 1]
  ]

showScoreGrid :: ScoreGrid -> String
showScoreGrid grid = concat
  [ printf "%6.2f" (grid ! (x,y))
  ++ (if x == width' then "\n" else "|")
  | y <- [0..height']
  , x <- [0..width']
  ] where
    ((0,0), (width', height')) = bounds grid

showTracking :: TrackingGrid -> String
showTracking grid = concat
  [(case grid ! ((x,y) :: Pos) of
      Nothing -> " "
      Just Water -> "~"
      Just Hit -> "H"
      Just Sunk -> "S")
  ++ (if x == width' then "\n" else "")
  | y <- [0..height']
  , x <- [0..width']
  ] where
    ((0,0), (width', height')) = bounds grid

showFleetPlacement :: FleetPlacement -> String
showFleetPlacement fleet = tail $ concat
  [ (if x == 0 then "\n" else "") ++
    (if isJust . shipAt fleet $ (x,y) then "O" else "~")
  | y <- [0..height - 1]
  , x <- [0..width - 1]
  ] where (width, height) = boardSize

showFleet :: Fleet -> String
showFleet = showFleetPlacement . map shipShape . Map.elems

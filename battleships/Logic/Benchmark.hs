{-# LANGUAGE RecordWildCards #-}
module Logic.Benchmark where

import           Control.Monad.Random
import           Control.Monad.State.Class (MonadState)
import           Control.Monad.Trans.State (runStateT)
import           Data.Array
import qualified Data.Map as Map
import           Data.List (sort)
import           Logic.Game
-- import           Logic.StupidAI
import           Logic.CleverAI
import           Logic.AIUtil
import           Logic.Debug
import           Data.Maybe
import           Prelude

-- | Tests the performance of the AI, that is the average number of shots
-- | needed to sink all the ships. This way, we can estimate how well the AI plays.
-- | The AI plays against itself.
benchmark :: Int -> IO ()
benchmark repetitions = do
  shotCounts <- mapM f [1..repetitions]
  let sorted = sort shotCounts
  let avg = (fromIntegral $ sum shotCounts :: Double) / (fromIntegral $ length shotCounts)
  let mn = minimum shotCounts
  let mx = maximum shotCounts
  let mdn = sorted !! (length sorted `div` 2)
  putStrLn $ "Average: " ++ show avg ++ " shots."
  putStrLn $ "Minimum: " ++ show mn ++ " shots."
  putStrLn $ "Maximum: " ++ show mx ++ " shots."
  putStrLn $ "Median:  " ++ show mdn ++ " shots."
  putStrLn $ "Complete list: "
  mapM_ print $ sorted where
    f :: Int -> IO Int
    f i = do
      putStrLn $ "\n---\n" ++ show i ++ "th run:"
      shotCount <- playGame
      putStrLn $ show shotCount ++ " shots needed."
      return shotCount

-- | Returns number of shots the AI needed.
playGame :: IO Int
playGame = do
  (ai, fleetPlacement) <- aiInit rules
  putStrLn $ showFleetPlacement rules fleetPlacement
  let fleet = generateFleet fleetPlacement
  (count, _newAi) <- runStateT (turn impact fleet Map.empty 0) (ai :: CleverAI)
  return count where
    impact = newGrid (rulesSize rules) Nothing

-- | Let the AI play against itself. Returns the number of shots fired.
turn :: (AI a, MonadRandom m, MonadState a m) => TrackingGrid -> Fleet -> Fleet -> Int -> m Int
turn impact fleet sunk count = do
    -- get target position from AI
    pos <- aiFire
    -- fire the AI's shot against itself
    let
      (response, fleet', sunk') = case shipAt (fleet Map.\\ sunk)
                                $ debug' (\p -> "AI's target: " ++ show p) pos of
        Nothing   ->  (Water, fleet, sunk)
        Just ship ->
          let
            -- inflict damage to the ship
            Just idx = shipCellIndex pos ship
            newShip  = damageShip idx ship
            -- replace ship
            newFleet = Map.insert (shipID ship) newShip fleet
          in if isShipSunk newShip
             then (Sunk, newFleet, Map.insert (shipID ship) newShip sunk)
             else (Hit, newFleet, sunk)
    -- update the impact grid
    let newImpact   = impact // [(pos, Just response)]
    -- notify the AI
    aiResponse pos response
    -- should any ships be moved?
    fleet'' <- if rulesMove rules
               then do
                      mMove <- aiMove fleet' {- >>= \a ->  debug' (\_ -> "AI's movement: " ++ show a) $ return a -}
                      return $ case mMove of
                        Nothing -> fleet'
                        Just (shipID, movement) -> case Map.lookup shipID fleet' of
                          Just ship -> if not $ isDamaged ship
                                       then moveShip ship movement rules fleet'
                                       else fleet'
                          Nothing   -> fleet'
               else return fleet'
    -- all ships sunk now?
    case allSunk fleet'' of
      True  -> return (count + 1)
      False -> turn
                  newImpact
                  ( debug' (\f -> "Fleet:\n" ++ showFleet rules f) fleet'')
                  ( debug' (\f -> "Sunk:\n" ++ showFleet rules f) sunk'  )
                  (count + 1)

rules :: Rules
rules = Rules (10, 10) [ 5, 4, 4, 3, 3, 3, 2, 2, 2, 2 ] 1 False True

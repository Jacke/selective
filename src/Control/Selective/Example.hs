{-# LANGUAGE ConstraintKinds, DeriveFunctor, GADTs, RankNTypes #-}
module Control.Selective.Example where

import Algebra.Graph
import Algebra.Graph.Export.Dot
import Control.Monad
import Control.Selective.Free.Rigid

import qualified Build.Task as B
import qualified Data.Set as Set

------------------------------- Ping-pong example ------------------------------
pingPongM :: IO ()
pingPongM = getLine
            >>=
            \s -> if s == "ping" then putStrLn "pong" else pure ()

pingPongA :: IO ()
pingPongA = fmap (\_ -> id) getLine
            <*>
            putStrLn "pong"

pingPongS :: IO ()
pingPongS =
    (\s -> if s == "ping" then Left () else Right ()) <$> getLine
    <*?
    (putStrLn "pong" *> pure id)

pingPongDoM :: IO ()
pingPongDoM = do
    s <- getLine
    when (s == "ping") (putStrLn "pong")

pingPongWhenS :: IO ()
pingPongWhenS = whenS (fmap (=="ping") getLine) (putStrLn "pong")

-- Doesn't make much sense, there are still opaque binds, furthermore getLine
-- might happen twice.
pingPongMP :: IO ()
pingPongMP = mplus x y
  where
    x = do
        x <- getLine
        guard (x == "ping")
        putStrLn "pong"
    y = do
        x <- getLine
        guard (x /= "ping")

------------------------------- Task dependencies ------------------------------

-- dependencies task "B1" = ["A2","B2","C1"]
-- dependencies task "B2" = ["A1","B1","C1"]
-- dependencies task "A1" = []
task :: B.Tasks Selective String Integer
task "B1" = Just $ B.Task $ \fetch -> ifS ((1==) <$> fetch "C1") (fetch "B2") (fetch "A2")
task "B2" = Just $ B.Task $ \fetch -> ifS ((1==) <$> fetch "C1") (fetch "A1") (fetch "B1")
task _    = Nothing

-- dependencies task2 "B1" == ["A1","A2","C5","C6","D5","D6"]
task2 :: B.Tasks Selective String Integer
task2 "B1" = Just $ B.Task $ \fetch -> (odd <$> fetch "A1") `bindS` \x ->
                                       (odd <$> fetch "A2") `bindS` \y ->
                                          let c = if x then "C" else "D"
                                              n = if y then "5" else "6"
                                          in fetch (c ++ n)
task2 _    = Nothing

data Key = A Int | B Int | C Int Int deriving (Eq, Show)

editDistance :: B.Tasks Selective Key Int
editDistance (C i 0) = Just $ B.Task $ const $ pure i
editDistance (C 0 j) = Just $ B.Task $ const $ pure j
editDistance (C i j) = Just $ B.Task $ \fetch ->
    ((==) <$> fetch (A i) <*> fetch (B j)) `bindS` \equals ->
        if equals
            then fetch (C (i - 1) (j - 1))
            else (\insert delete replace -> 1 + minimum [insert, delete, replace])
                 <$> fetch (C  i      (j - 1))
                 <*> fetch (C (i - 1)  j     )
                 <*> fetch (C (i - 1) (j - 1))
editDistance _ = Nothing

sprsh1 :: B.Tasks Applicative String Int
sprsh1 "B1" = Just $ B.Task $ \fetch -> ((+)  <$> fetch "A1" <*> fetch "A2")
sprsh1 "B2" = Just $ B.Task $ \fetch -> ((*2) <$> fetch "B1")
sprsh1 "C8" = Just $ B.Task $ \_ -> pure 8
sprsh1 _    = Nothing

-- Code from the paper:

newtype Task k v = Task { run :: forall f. Selective f => (k -> f v) -> f v }

type Script k v = k -> Maybe (Task k v)

tar :: Applicative f => [f String] -> f String
tar xs = concat <$> sequenceA xs

parse :: Functor f => f String -> f Bool
parse = fmap null

compile :: Applicative f => [f String] -> f String
compile xs = concat <$> sequenceA xs

script :: Script FilePath String
script "release.tar" = Just $ Task $ \fetch -> tar [fetch "LICENSE", fetch "exe"]
script "exe" = Just $ Task $ \fetch ->
    let src   = fetch "src.ml"
        cfg   = fetch "config"
        libc  = fetch "lib.c"
        libml = fetch "lib.ml"
    in compile [src, ifS (parse cfg) libc libml]
script _ = Nothing

dependenciesOver :: Task k v -> [k]
dependenciesOver task = getOver $ run task (\k -> Over [k])

dependenciesUnder :: Task k v -> [k]
dependenciesUnder task = getUnder $ run task (\k -> Under [k])

--------------------------------- Free example ---------------------------------

data F k v a = Fetch k (v -> a)
    deriving Functor

instance Show k => Show (F k v a) where
    show (Fetch k _) = "(Fetch " ++ show k ++ ")"

fetch :: k -> Select (F k v) v
fetch key = liftSelect $ Fetch key id

data GP k v a = Get k (v -> a)
              | Put k v a
    deriving Functor

instance (Show k, Show v) => Show (GP k v a) where
    show (Get k   _) = "(Get " ++ show k ++ ")"
    show (Put k v _) = "(Put " ++ show k ++ " " ++ show v ++ ")"

get :: k -> Select (GP k v) v
get key = liftSelect $ Get key id

put :: k -> v -> Select (GP k v) ()
put key value = liftSelect $ Put key value ()

graph :: Ord k => (k -> [k]) -> k -> Graph k
graph deps key = transpose $ overlays [ star k (deps k) | k <- keys Set.empty [key] ]
  where
    keys seen []   = Set.toList seen
    keys seen (x:xs)
        | x `Set.member` seen = keys seen xs
        | otherwise           = keys (Set.insert x seen) (deps x ++ xs)

-- | Extract dependencies from a selective task.
dependencies :: B.Task Selective k v -> [k]
dependencies task = getOver $ B.run task (Over . pure)

draw :: B.Tasks Selective String v -> String -> String
draw tasks = exportAsIs . graph deps
  where
    deps k = maybe [] dependencies $ tasks k

fetchIO :: Read a => String -> IO a
fetchIO prompt = do putStr (prompt ++ ": "); read <$> getLine

---------------------------------- Validation ----------------------------------

type Radius = Word
type Width  = Word
type Height = Word

data Shape = Circle Radius | Rectangle Width Height deriving Show

-- Some validation examples:
--
-- > shape (Success True) (Success 1) (Failure ["width?"]) (Failure ["height?"])
-- > Success (Circle 1)
--
-- > shape (Success False) (Failure ["radius?"]) (Success 2) (Success 3)
-- > Success (Rectangle 2 3)
--
-- > shape (Success False) (Failure ["radius?"]) (Success 2) (Failure ["height?"])
-- > Failure ["height?"]
--
-- > shape (Success False) (Success 1) (Failure ["width?"]) (Failure ["height?"])
-- > Failure ["width?", "height?"]
--
-- > shape (Failure ["choice?"]) (Failure ["radius?"]) (Success 2) (Failure ["height?"])
-- > Failure ["choice?"]
shape :: Selective f => f Bool -> f Radius -> f Width -> f Height -> f Shape
shape s r w h = ifS s (Circle <$> r) (Rectangle <$> w <*> h)

-- > s1 = shape (Failure ["choice 1?"]) (Success 1) (Failure ["width 1?"]) (Success 3)
-- > s2 = shape (Success False) (Success 1) (Success 2) (Failure ["height 2?"])
-- > twoShapes s1 s2
-- > Failure ["choice 1?","height 2?"]
twoShapes :: Selective f => f Shape -> f Shape -> f (Shape, Shape)
twoShapes s1 s2 = (,) <$> s1 <*> s2

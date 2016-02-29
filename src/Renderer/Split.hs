{-# LANGUAGE FlexibleInstances #-}
module Renderer.Split where

import Prelude hiding (div, head, span)
import Category
import Diff
import Line
import Row
import Patch
import Renderer
import Term
import Syntax
import Control.Comonad.Cofree
import Range
import Control.Monad.Free
import Text.Blaze.Html
import Text.Blaze.Html5 hiding (map)
import qualified Text.Blaze.Internal as Blaze
import qualified Text.Blaze.Html5.Attributes as A
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Text.Blaze.Html.Renderer.Text
import Data.Either
import Data.Foldable
import Data.Functor.Identity
import Data.Monoid
import qualified Data.OrderedMap as Map
import qualified Data.Set as Set
import Source hiding ((++))

type ClassName = T.Text

-- | Add the first category from a Foldable of categories as a class name as a
-- | class name on the markup, prefixed by `category-`.
classifyMarkup :: Foldable f => f Category -> Markup -> Markup
classifyMarkup categories element = maybe element ((element !) . A.class_ . stringValue . styleName) $ maybeFirst categories

-- | Return the appropriate style name for the given category.
styleName :: Category -> String
styleName category = "category-" ++ case category of
  BinaryOperator -> "binary-operator"
  DictionaryLiteral -> "dictionary"
  Pair -> "pair"
  FunctionCall -> "function_call"
  StringLiteral -> "string"
  SymbolLiteral -> "symbol"
  IntegerLiteral -> "integer"
  Other string -> string

-- | Render a diff as an HTML split diff.
split :: Renderer leaf TL.Text
split diff (beforeBlob, afterBlob) = renderHtml
  . docTypeHtml
    . ((head $ link ! A.rel "stylesheet" ! A.href "style.css") <>)
    . body
      . (table ! A.class_ (stringValue "diff")) $
        ((colgroup $ (col ! A.width (stringValue . show $ columnWidth)) <> col <> (col ! A.width (stringValue . show $ columnWidth)) <> col) <>)
        . mconcat $ numberedLinesToMarkup <$> reverse numbered
  where
    before = Source.source beforeBlob
    after = Source.source afterBlob
    rows = fst (splitDiffByLines diff (0, 0) (before, after))
    numbered = foldl' numberRows [] rows
    maxNumber = case numbered of
      [] -> 0
      ((x, _, y, _) : _) -> max x y

    -- | The number of digits in a number (e.g. 342 has 3 digits).
    digits :: Int -> Int
    digits n = let base = 10 :: Int in
      ceiling (logBase (fromIntegral base) (fromIntegral n) :: Double)

    columnWidth = max (20 + digits maxNumber * 8) 40

    -- | Render a line with numbers as an HTML row.
    numberedLinesToMarkup :: (Int, Line (SplitDiff a Info), Int, Line (SplitDiff a Info)) -> Markup
    numberedLinesToMarkup (m, left, n, right) = tr $ toMarkup (or $ hasChanges <$> left, m, renderable before left) <> toMarkup (or $ hasChanges <$> right, n, renderable after right) <> string "\n"

    renderable source = fmap (Renderable . (,) source)

    hasChanges diff = or $ const True <$> diff

    -- | Add a row to list of tuples of ints and lines, where the ints denote
    -- | how many non-empty lines exist on that side up to that point.
    numberRows :: [(Int, Line a, Int, Line a)] -> Row a -> [(Int, Line a, Int, Line a)]
    numberRows rows (Row left right) = (leftCount rows + valueOf left, left, rightCount rows + valueOf right, right) : rows
      where
        leftCount [] = 0
        leftCount ((x, _, _, _):_) = x
        rightCount [] = 0
        rightCount ((_, _, x, _):_) = x
        valueOf EmptyLine = 0
        valueOf _ = 1

-- | A patch to only one side of a diff.
data SplitPatch a = SplitInsert a | SplitDelete a | SplitReplace a
  deriving (Show, Eq)

-- | A diff with only one side’s annotations.
type SplitDiff leaf annotation = Free (Annotated leaf annotation) (SplitPatch (Term leaf annotation))

-- | Something that can be rendered as markup.
newtype Renderable a = Renderable (Source Char, a)

instance ToMarkup f => ToMarkup (Renderable (Info, Syntax a (f, Range))) where
  toMarkup (Renderable (source, (Info range categories, syntax))) = classifyMarkup categories $ case syntax of
    Leaf _ -> span . string . toString $ slice range source
    Indexed children -> ul . mconcat $ wrapIn li <$> contentElements children
    Fixed children -> ul . mconcat $ wrapIn li <$> contentElements children
    Keyed children -> dl . mconcat $ wrapIn dd <$> contentElements children
    where markupForSeparatorAndChild :: ToMarkup f => ([Markup], Int) -> (f, Range) -> ([Markup], Int)
          markupForSeparatorAndChild (rows, previous) (child, range) = (rows ++ [ string  (toString $ slice (Range previous $ start range) source), toMarkup child ], end range)

          wrapIn _ l@Blaze.Leaf{} = l
          wrapIn _ l@Blaze.CustomLeaf{} = l
          wrapIn _ l@Blaze.Content{} = l
          wrapIn _ l@Blaze.Comment{} = l
          wrapIn f p = f p

          contentElements children = let (elements, previous) = foldl' markupForSeparatorAndChild ([], start range) children in
            elements ++ [ string . toString $ slice (Range previous $ end range) source ]

instance ToMarkup (Renderable (Term a Info)) where
  toMarkup (Renderable (source, term)) = fst $ cata (\ info@(Info range _) syntax -> (toMarkup $ Renderable (source, (info, syntax)), range)) term

instance ToMarkup (Renderable (SplitDiff a Info)) where
  toMarkup (Renderable (source, diff)) = fst $ iter (\ (Annotated info@(Info range _) syntax) -> (toMarkup $ Renderable (source, (info, syntax)), range)) $ toMarkupAndRange <$> diff
    where toMarkupAndRange :: SplitPatch (Term a Info) -> (Markup, Range)
          toMarkupAndRange patch = let term@(Info range _ :< _) = getSplitTerm patch in
            ((div ! A.class_ (splitPatchToClassName patch) ! A.data_ (stringValue . show $ termSize term)) . toMarkup $ Renderable (source, term), range)

-- | Pick the class name for a split patch.
splitPatchToClassName :: SplitPatch a -> AttributeValue
splitPatchToClassName patch = stringValue $ "patch " ++ case patch of
  SplitInsert _ -> "insert"
  SplitDelete _ -> "delete"
  SplitReplace _ -> "replace"

-- | Get the term from a split patch.
getSplitTerm :: SplitPatch a -> a
getSplitTerm (SplitInsert a) = a
getSplitTerm (SplitDelete a) = a
getSplitTerm (SplitReplace a) = a

-- | Split a diff, which may span multiple lines, into rows of split diffs.
splitDiffByLines :: Diff leaf Info -> (Int, Int) -> (Source Char, Source Char) -> ([Row (SplitDiff leaf Info)], (Range, Range))
splitDiffByLines diff (prevLeft, prevRight) sources = case diff of
  Free (Annotated annotation syntax) -> (splitAnnotatedByLines sources (ranges annotation) (categories annotation) syntax, ranges annotation)
  Pure (Insert term) -> let (lines, range) = splitTermByLines term (snd sources) in
    (Row EmptyLine . fmap (Pure . SplitInsert) <$> lines, (Range prevLeft prevLeft, range))
  Pure (Delete term) -> let (lines, range) = splitTermByLines term (fst sources) in
    (flip Row EmptyLine . fmap (Pure . SplitDelete) <$> lines, (range, Range prevRight prevRight))
  Pure (Replace leftTerm rightTerm) -> let (leftLines, leftRange) = splitTermByLines leftTerm (fst sources)
                                           (rightLines, rightRange) = splitTermByLines rightTerm (snd sources) in
                                           (zipWithDefaults Row EmptyLine EmptyLine (fmap (Pure . SplitReplace) <$> leftLines) (fmap (Pure . SplitReplace) <$> rightLines), (leftRange, rightRange))
  where categories (Info _ left, Info _ right) = (left, right)
        ranges (Info left _, Info right _) = (left, right)

-- | A functor that can return its content.
class Functor f => Has f where
  get :: f a -> a

instance Has Identity where
  get = runIdentity

instance Has ((,) a) where
  get = snd

-- | Takes a term and a source and returns a list of lines and their range within source.
splitTermByLines :: Term leaf Info -> Source Char -> ([Line (Term leaf Info)], Range)
splitTermByLines (Info range categories :< syntax) source = flip (,) range $ case syntax of
  Leaf a -> pure . (:< Leaf a) . (`Info` categories) <$> actualLineRanges range source
  Indexed children -> adjoinChildLines (Indexed . fmap get) (Identity <$> children)
  Fixed children -> adjoinChildLines (Fixed . fmap get) (Identity <$> children)
  Keyed children -> adjoinChildLines (Keyed . Map.fromList) (Map.toList children)
  where adjoin :: Has f => [Line (Either Range (f (Term leaf Info)))] -> [Line (Either Range (f (Term leaf Info)))]
        adjoin = reverse . foldl (adjoinLinesBy $ openEither (openRange source) (openTerm source)) []

        adjoinChildLines :: Has f => ([f (Term leaf Info)] -> Syntax leaf (Term leaf Info)) -> [f (Term leaf Info)] -> [Line (Term leaf Info)]
        adjoinChildLines constructor children = let (lines, previous) = foldl childLines ([], start range) children in
          fmap (wrapLineContents $ wrap constructor) . adjoin $ lines ++ (pure . Left <$> actualLineRanges (Range previous $ end range) source)

        wrap :: Has f => ([f (Term leaf Info)] -> Syntax leaf (Term leaf Info)) -> [Either Range (f (Term leaf Info))] -> Term leaf Info
        wrap constructor children = (Info (unionRanges $ getRange <$> children) categories :<) . constructor $ rights children

        getRange :: Has f => Either Range (f (Term leaf Info)) -> Range
        getRange (Right term) = case get term of (Info range _ :< _) -> range
        getRange (Left range) = range

        childLines :: Has f => ([Line (Either Range (f (Term leaf Info)))], Int) -> f (Term leaf Info) -> ([Line (Either Range (f (Term leaf Info)))], Int)
        childLines (lines, previous) child = let (childLines, childRange) = splitTermByLines (get child) source in
          (adjoin $ lines ++ (pure . Left <$> actualLineRanges (Range previous $ start childRange) source) ++ (fmap (Right . (<$ child)) <$> childLines), end childRange)

-- | Split a annotated diff into rows of split diffs.
splitAnnotatedByLines :: (Source Char, Source Char) -> (Range, Range) -> (Set.Set Category, Set.Set Category) -> Syntax leaf (Diff leaf Info) -> [Row (SplitDiff leaf Info)]
splitAnnotatedByLines sources ranges categories syntax = case syntax of
  Leaf a -> wrapRowContents (Free . (`Annotated` Leaf a) . (`Info` fst categories) . unionRanges) (Free . (`Annotated` Leaf a) . (`Info` snd categories) . unionRanges) <$> contextRows ranges sources
  Indexed children -> adjoinChildRows (Indexed . fmap get) (Identity <$> children)
  Fixed children -> adjoinChildRows (Fixed . fmap get) (Identity <$> children)
  Keyed children -> adjoinChildRows (Keyed . Map.fromList) (Map.toList children)
  where contextRows :: (Range, Range) -> (Source Char, Source Char) -> [Row Range]
        contextRows ranges sources = zipWithDefaults Row EmptyLine EmptyLine
          (pure <$> actualLineRanges (fst ranges) (fst sources))
          (pure <$> actualLineRanges (snd ranges) (snd sources))

        adjoin :: Has f => [Row (Either Range (f (SplitDiff leaf Info)))] -> [Row (Either Range (f (SplitDiff leaf Info)))]
        adjoin = reverse . foldl (adjoinRowsBy (openEither (openRange $ fst sources) (openDiff $ fst sources)) (openEither (openRange $ snd sources) (openDiff $ snd sources))) []

        adjoinChildRows :: (Has f) => ([f (SplitDiff leaf Info)] -> Syntax leaf (SplitDiff leaf Info)) -> [f (Diff leaf Info)] -> [Row (SplitDiff leaf Info)]
        adjoinChildRows constructor children = let (rows, previous) = foldl childRows ([], starts ranges) children in
          fmap (wrapRowContents (wrap constructor (fst categories)) (wrap constructor (snd categories))) . adjoin $ rows ++ (fmap Left <$> contextRows (makeRanges previous (ends ranges)) sources)

        wrap :: Has f => ([f (SplitDiff leaf Info)] -> Syntax leaf (SplitDiff leaf Info)) -> Set.Set Category -> [Either Range (f (SplitDiff leaf Info))] -> SplitDiff leaf Info
        wrap constructor categories children = Free . Annotated (Info (unionRanges $ getRange <$> children) categories) . constructor $ rights children

        getRange :: Has f => Either Range (f (SplitDiff leaf Info)) -> Range
        getRange (Right diff) = case get diff of
          (Pure patch) -> let Info range _ :< _ = getSplitTerm patch in range
          (Free (Annotated (Info range _) _)) -> range
        getRange (Left range) = range

        childRows :: (Has f) => ([Row (Either Range (f (SplitDiff leaf Info)))], (Int, Int)) -> f (Diff leaf Info) -> ([Row (Either Range (f (SplitDiff leaf Info)))], (Int, Int))
        childRows (rows, previous) child = let (childRows, childRanges) = splitDiffByLines (get child) previous sources in
          (adjoin $ rows ++ (fmap Left <$> contextRows (makeRanges previous (starts childRanges)) sources) ++ (fmap (Right . (<$ child)) <$> childRows), ends childRanges)

        starts (left, right) = (start left, start right)
        ends (left, right) = (end left, end right)
        makeRanges (leftStart, rightStart) (leftEnd, rightEnd) = (Range leftStart leftEnd, Range rightStart rightEnd)

-- | Returns a function that takes an Either, applies either the left or right
-- | MaybeOpen, and returns Nothing or the original either.
openEither :: MaybeOpen a -> MaybeOpen b -> MaybeOpen (Either a b)
openEither ifLeft ifRight which = either (fmap (const which) . ifLeft) (fmap (const which) . ifRight) which

-- | Given a source and a range, returns nothing if it ends with a `\n`;
-- | otherwise returns the range.
openRange :: Source Char -> MaybeOpen Range
openRange source range = case (source `at`) <$> maybeLastIndex range of
  Just '\n' -> Nothing
  _ -> Just range

-- | Given a source and something that has a term, returns nothing if the term
-- | ends with a `\n`; otherwise returns the term.
openTerm :: Has f => Source Char -> MaybeOpen (f (Term leaf Info))
openTerm source term = const term <$> openRange source (case get term of (Info range _ :< _) -> range)

-- | Given a source and something that has a split diff, returns nothing if the
-- | diff ends with a `\n`; otherwise returns the diff.
openDiff :: Has f => Source Char -> MaybeOpen (f (SplitDiff leaf Info))
openDiff source diff = const diff <$> case get diff of
  (Free (Annotated (Info range _) _)) -> openRange source range
  (Pure patch) -> let Info range _ :< _ = getSplitTerm patch in openRange source range

-- | Zip two lists by applying a function, using the default values to extend
-- | the shorter list.
zipWithDefaults :: (a -> b -> c) -> a -> b -> [a] -> [b] -> [c]
zipWithDefaults f da db a b = take (max (length a) (length b)) $ zipWith f (a ++ repeat da) (b ++ repeat db)
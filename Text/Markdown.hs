{-# LANGUAGE OverloadedStrings #-}
module Text.Markdown
    ( MarkdownSettings
    , msXssProtect
    , def
    , markdown
    , Markdown (..)
    ) where

import Text.Markdown.Inline
import Text.Markdown.Block
import Prelude hiding (sequence, takeWhile)
import Data.Default (Default (..))
import Data.Text (Text)
import qualified Data.Text.Lazy as TL
import Text.Blaze.Html (ToMarkup (..), Html)
import Text.Blaze.Html.Renderer.Text (renderHtml)
import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL
import Data.Monoid (Monoid (mappend, mempty, mconcat))
import Data.Functor.Identity (runIdentity)
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as HA
import Text.HTML.SanitizeXSS (sanitizeBalance)

data MarkdownSettings = MarkdownSettings
    { msXssProtect :: Bool
    }

instance Default MarkdownSettings where
    def = MarkdownSettings
        { msXssProtect = True
        }

newtype Markdown = Markdown TL.Text

instance ToMarkup Markdown where
    toMarkup (Markdown t) = markdown def t

markdown :: MarkdownSettings -> TL.Text -> Html
markdown ms tl =
            runIdentity
          $ CL.sourceList (TL.toChunks $ TL.filter (/= '\r') tl)
       C.$$ markdownSink ms

markdownSink :: Monad m
             => MarkdownSettings
             -> C.Sink Text m Html
markdownSink ms = markdownConduit ms C.=$ CL.fold mappend mempty

markdownConduit :: Monad m
                => MarkdownSettings
                -> C.Conduit Text m Html
markdownConduit ms = C.mapOutput (fmap (toHtmlI ms . toInline)) toBlocks C.=$= toHtmlB ms

data MState = NoState | InList ListType

toHtmlB :: Monad m => MarkdownSettings -> C.GInfConduit (Block Html) m Html
toHtmlB ms =
    loop NoState
  where
    loop state = C.awaitE >>= either
        (\e -> closeState state >> return e)
        (\x -> do
            state' <- getState state x
            C.yield $ go x
            loop state')

    closeState NoState = return ()
    closeState (InList Unordered) = C.yield $ escape "</ul>"
    closeState (InList Ordered) = C.yield $ escape "</ol>"

    getState NoState (BlockList ltype _) = do
        C.yield $ escape $
            case ltype of
                Unordered -> "<ul>"
                Ordered -> "<ol>"
        return $ InList ltype
    getState NoState _ = return NoState
    getState state@(InList lt1) b@(BlockList lt2 _)
        | lt1 == lt2 = return state
        | otherwise = closeState state >> getState NoState b
    getState state@(InList _) _ = closeState state >> return NoState

    go (BlockPara h) = H.p h
    go (BlockList _ (Left h)) = H.li h
    go (BlockList _ (Right bs)) = H.li $ blocksToHtml bs
    go (BlockHtml t) = escape $ (if msXssProtect ms then sanitizeBalance else id) t
    go (BlockCode Nothing t) = H.pre $ H.code $ toMarkup t
    go (BlockCode (Just lang) t) = H.pre $ H.code H.! HA.class_ (H.toValue lang) $ toMarkup t
    go (BlockQuote bs) = H.blockquote $ blocksToHtml bs
    go BlockRule = H.hr
    go (BlockHeading level h) =
        wrap level h
      where
       wrap 1 = H.h1
       wrap 2 = H.h2
       wrap 3 = H.h3
       wrap 4 = H.h4
       wrap 5 = H.h5
       wrap _ = H.h6

    blocksToHtml bs = runIdentity $ mapM_ C.yield bs C.$$ toHtmlB ms C.=$ CL.fold mappend mempty

escape :: Text -> Html
escape = preEscapedToMarkup

toHtmlI :: MarkdownSettings -> [Inline] -> Html
toHtmlI ms is0
    | msXssProtect ms = escape $ sanitizeBalance $ TL.toStrict $ renderHtml final
    | otherwise = final
  where
    final = gos is0
    gos = mconcat . map go

    go (InlineText t) = toMarkup t
    go (InlineItalic is) = H.i $ gos is
    go (InlineBold is) = H.b $ gos is
    go (InlineCode t) = H.code $ toMarkup t
    go (InlineLink url Nothing content) = H.a H.! HA.href (H.toValue url) $ gos content
    go (InlineLink url (Just title) content) = H.a H.! HA.href (H.toValue url) H.! HA.title (H.toValue title) $ gos content
    go (InlineImage url Nothing content) = H.img H.! HA.src (H.toValue url) H.! HA.alt (H.toValue content)
    go (InlineImage url (Just title) content) = H.img H.! HA.src (H.toValue url) H.! HA.alt (H.toValue content) H.! HA.title (H.toValue title)
    go (InlineHtml t) = escape t

{-
nonEmptyLines :: Parser [Html]
nonEmptyLines = map line <$> nonEmptyLinesText

nonEmptyLinesText :: Parser [Text]
nonEmptyLinesText =
    go id
  where
    go :: ([Text] -> [Text]) -> Parser [Text]
    go front = do
        l <- takeWhile (/= '\n')
        _ <- optional $ skip (== '\n')
        if T.null l then return (front []) else go $ front . (l:)

(<>) :: Monoid m => m -> m -> m
(<>) = mappend

parser :: MarkdownSettings -> Parser Html
parser ms =
    html
    <|> rules
    <|> hashheads <|> underheads
    <|> codeblock
    <|> blockquote
    <|> bullets
    <|> numbers
    <|> para
  where
    html = do
        c <- char '<'
        ls' <- nonEmptyLinesText
        let ls =
                case ls' of
                    a:b -> T.cons c a:b
                    [] -> [T.singleton c]
        let t = T.intercalate "\n" ls
        let t' = if msXssProtect ms then sanitizeBalance t else t
        return $ preEscapedToMarkup t'

    rules =
            (string "* * *\n" *> return H.hr)
        <|> (try $ string "* * *" *> endOfInput *> return H.hr)
        <|> (string "***\n" *> return H.hr)
        <|> (try $ string "***" *> endOfInput *> return H.hr)
        <|> (string "*****\n" *> return H.hr)
        <|> (try $ string "*****" *> endOfInput *> return H.hr)
        <|> (string "- - -\n" *> return H.hr)
        <|> (try $ string "- - -" *> endOfInput *> return H.hr)
        <|> (try $ do
            x <- takeWhile1 (== '-')
            char' '\n' <|> endOfInput
            if T.length x >= 5
                then return H.hr
                else fail "not enough dashes"
                    )

    para = do
        ls <- nonEmptyLines
        return $ if (null ls)
            then mempty
            else H.p $ foldr1
                    (\a b -> a <> "\n" <> b) ls

    hashheads = do
        _c <- char '#'
        x <- takeWhile (== '#')
        skipSpace
        l <- takeWhile (/= '\n')
        let h =
                case T.length x of
                    0 -> H.h1
                    1 -> H.h2
                    2 -> H.h3
                    3 -> H.h4
                    4 -> H.h5
                    _ -> H.h6
        return $ h $ line $ T.dropWhileEnd isSpace $ T.dropWhileEnd (== '#') l

    underheads = try $ do
        x <- takeWhile (/= '\n')
        _ <- char '\n'
        y <- satisfy $ inClass "=-"
        ys <- takeWhile (== y)
        unless (T.length ys >= 2) $ fail "Not enough unders"
        _ <- char '\n'
        let l = line x
        return $ (if y == '=' then H.h1 else H.h2) l

    codeblock = H.pre . H.code . mconcat . map toHtml . intersperse "\n"
            <$> many1 indentedLine

    blockquote = H.blockquote . markdown ms . TL.fromChunks . intersperse "\n"
             <$> many1 blockedLine

    bullets = H.ul . mconcat <$> many1 (bullet ms)
    numbers = H.ol . mconcat <$> many1 (number ms)

string' :: Text -> Parser ()
string' s = string s *> return ()

bulletStart :: Parser ()
bulletStart = string' "* " <|> string' "- " <|> string' "+ "

bullet :: MarkdownSettings -> Parser Html
bullet _ms = do
    bulletStart
    content <- itemContent
    return $ H.li content

numberStart :: Parser ()
numberStart =
    try $ decimal' *> satisfy (inClass ".)") *> char' ' '
  where
    decimal' :: Parser Int
    decimal' = decimal

number :: MarkdownSettings -> Parser Html
number _ms = do
    numberStart
    content <- itemContent
    return $ H.li content

itemContent :: Parser Html
itemContent = do
    t <- takeWhile (/= '\n') <* (optional $ char' '\n')
    return $ line t

indentedLine :: Parser Text
indentedLine = string "    " *> takeWhile (/= '\n') <* (optional $ char '\n')

blockedLine :: Parser Text
blockedLine = (string ">\n" *> return "") <|>
              (string "> " *> takeWhile (/= '\n') <* (optional $ char '\n'))

line :: Text -> Html
line t =
    preEscapedToMarkup $ sanitizeBalance $ TL.toStrict $ renderHtml h
  where
    h = either error mconcat $ parseOnly (many phrase) t

phrase :: Parser Html
phrase =
    boldU <|> italicU <|> underscore <|>
    bold <|> italic <|> asterisk <|>
    code <|> backtick <|>
    escape <|>
    img <|> exclamationPoint <|>
    githubLink <|> link <|> leftBracket <|>
    tag <|> lessThan <|>
    normal
  where
    bold = try $ H.b <$> (string "**" *> phrase <* string "**")
    italic = try $ H.i <$> (char '*' *> phrase <* char '*')
    asterisk = toHtml <$> takeWhile1 (== '*')

    boldU = try $ H.b <$> (string "__" *> phrase <* string "__")
    italicU = try $ H.i <$> (char '_' *> phrase <* char '_')
    underscore = toHtml <$> takeWhile1 (== '_')

    code = try $ H.code <$> (char '`' *> phrase <* char '`')
    backtick = toHtml <$> takeWhile1 (== '`')

    escape = char '\\' *>
        ((toHtml <$> satisfy (inClass "`*_\\")) <|>
         return "\\")

    normal = toHtml <$> takeWhile1 (notInClass "*_`\\![<")

    githubLink = try $ do
        _ <- string "[["
        t1 <- takeWhile1 (\c -> c /= '|' && c /= ']')
        mt2 <- (char '|' >> fmap Just (takeWhile1 (/= ']'))) <|>
               return Nothing
        _ <- string "]]"

        let (href', text) =
                case mt2 of
                    Nothing -> (t1, t1)
                    Just t2 -> (t2, t1)
        let href = T.map fix href'
            fix ' ' = '-'
            fix '/' = '-'
            fix c   = c
        return $ H.a ! HA.href (toValue href) $ toHtml text

    link = try $ do
        _ <- char '['
        t <- toHtml <$> takeWhile (/= ']')
        _ <- char ']'
        _ <- char '('
        h <- toValue <$> many1 hrefChar
        mtitle <- optional linkTitle
        _ <- char ')'
        return $ case mtitle of
            Nothing -> H.a ! HA.href h $ t
            Just title -> H.a ! HA.href h ! HA.title (toValue title) $ toHtml t

    img = try $ do
        _ <- char '!'
        _ <- char '['
        a <- toValue <$> takeWhile (/= ']')
        _ <- char ']'
        _ <- char '('
        h <- toValue <$> many1 hrefChar
        mtitle <- optional linkTitle -- links and images work the same way
        _ <- char ')'
        return $ case mtitle of
            Nothing -> H.img ! HA.src h ! HA.alt a
            Just title -> H.img ! HA.src h ! HA.alt a ! HA.title (toValue title)

    leftBracket = toHtml <$> takeWhile1 (== '[')
    exclamationPoint = toHtml <$> takeWhile1 (== '!')

    tag = try $ do
        _ <- char '<'
        name <- takeWhile1 $ \c -> not (isSpace c) && c /= '>'
        guard $ T.all (\c -> isAlpha c || c == '/') name
        rest <- takeWhile (/= '>')
        _ <- char '>'
        return $ preEscapedToMarkup $ T.concat ["<", name, rest, ">"]

    lessThan = char '<' >> return "<"

hrefChar :: Parser Char
hrefChar = (char '\\' *> anyChar) <|> satisfy (notInClass " )")

linkTitle :: Parser String
linkTitle = string " \"" *> many titleChar <* char '"'

titleChar :: Parser Char
titleChar = (char '\\' *> anyChar) <|> satisfy (/= '"')

char' :: Char -> Parser ()
char' c = char c *> return ()
-}

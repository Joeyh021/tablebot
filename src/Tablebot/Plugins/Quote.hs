{-# OPTIONS_GHC -Wno-unused-top-binds #-}

-- |
-- Module      : Tablebot.Plugins.Quote
-- Description : A more complex example using databases.
-- License     : MIT
-- Maintainer  : tagarople@gmail.com
-- Stability   : experimental
-- Portability : POSIX
--
-- This is an example plugin which allows user to @!quote add@ their favourite
-- quotes and then @!quote show n@ a particular quote.
module Tablebot.Plugins.Quote (quotePlugin) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson
import Data.Default (Default (def))
import Data.Maybe (catMaybes)
import Data.Text (Text, append, pack, unpack)
import Data.Time.Clock.System (SystemTime (systemSeconds), getSystemTime, systemToUTCTime)
import Database.Persist.Sqlite (Filter, SelectOpt (LimitTo, OffsetBy), entityVal, (==.))
import Database.Persist.TH
import Discord.Interactions
import Discord.Types
import GHC.Generics (Generic)
import GHC.Int (Int64)
import System.Random (randomRIO)
import Tablebot.Utility
import Tablebot.Utility.Database
import Tablebot.Utility.Discord
  ( getMessage,
    getMessageLink,
    getPrecedingMessage,
    getReplyMessage,
    interactionResponseCustomMessage,
    sendCustomMessage,
    sendMessage,
    toMention,
    toMention',
  )
import Tablebot.Utility.Embed
import Tablebot.Utility.Exception (BotException (GenericException, InteractionException), catchBot, throwBot)
import Tablebot.Utility.Permission (requirePermission)
import Tablebot.Utility.SmartParser
import Text.RawString.QQ (r)

-- Our Quote table in the database. This is fairly standard for Persistent,
-- however you should note the name of the migration made.
share
  [mkPersist sqlSettings, mkMigrate "quoteMigration"]
  [persistLowerCase|
Quote
    quote Text
    author Text
    submitter Text
    msgId Int
    cnlId Int
    time UTCTime
    deriving Show
|]

-- | @quoteReactionAdd@ creates an event for when a reaction is added to a message.
-- If the reaction is :speech_balloon:, the message is added as a quote
quoteReactionAdd :: ReactionAdd
quoteReactionAdd = ReactionAdd quoteReaction
  where
    quoteReaction ri
      | emojiName (reactionEmoji ri) == "\x1F4AC" = do
        m <- getMessage (reactionChannelId ri) (reactionMessageId ri)
        case m of
          Left _ -> pure ()
          Right mes -> addMessageQuote (reactionUserId ri) mes mes >>= sendCustomMessage mes
      | otherwise = return ()

-- | Our quote command, which combines various functions to create, display and update quotes.
quoteCommand :: Command
quoteCommand =
  Command
    "quote"
    (parseComm quoteComm)
    [addQuote, editQuote, thisQuote, authorQuote, showQuote, deleteQuote, randomQuote, exportQuotes, importQuotes, clearQuotes]
  where
    quoteComm ::
      WithError
        "Unknown quote functionality."
        (Either () (Either Int64 (RestOfInput Text))) ->
      Message ->
      DatabaseDiscord ()
    quoteComm (WErr (Left ())) m = randomQ m >>= sendCustomMessage m
    quoteComm (WErr (Right (Left t))) m = showQ t m >>= sendCustomMessage m
    quoteComm (WErr (Right (Right (ROI t)))) m = authorQ t m >>= sendCustomMessage m

addQuote :: Command
addQuote = Command "add" (parseComm addComm) []
  where
    addComm ::
      WithError "Quote format incorrect!\nFormat is: .quote \"quote\" - author" (Quoted Text, Exactly "-", RestOfInput Text) ->
      Message ->
      DatabaseDiscord ()
    addComm (WErr (Qu qu, _, ROI author)) m = addQ qu author m >>= sendCustomMessage m

editQuote :: Command
editQuote = Command "edit" (parseComm editComm) []
  where
    editComm ::
      WithError
        "Edit format incorrect!\nFormat is: .quote edit quoteId \"new quote\" - author"
        (Int64, Quoted Text, Exactly "-", RestOfInput Text) ->
      Message ->
      DatabaseDiscord ()
    editComm (WErr (qId, Qu qu, _, ROI author)) = editQ qId qu author

thisQuote :: Command
thisQuote = Command "this" (parseComm thisComm) []
  where
    thisComm :: Message -> DatabaseDiscord ()
    thisComm = thisQ

quoteMessageAppComm :: Maybe ApplicationCommandRecv
quoteMessageAppComm = appcomm >>= return . (`ApplicationCommandRecv` recv)
  where
    appcomm = createApplicationCommandMessage "quote"
    recv i@InteractionApplicationCommand {interactionDataApplicationCommand = InteractionDataApplicationCommandMessage {..}, ..} = do
      let mid = interactionDataApplicationCommandTargetId
      case interactionChannelId of
        Nothing -> throwBot $ InteractionException "no channel id in quote interaction"
        Just cid -> do
          m <- getMessage cid mid
          case m of
            Left _ -> throwBot $ InteractionException "could not get message to quote"
            Right msg -> interactionResponseCustomMessage i =<< addQ' (messageContent msg) (toMention $ messageAuthor msg) (toMention' $ parseUserId $ contextUserId i) mid cid i
    recv _ = return def

-- return $ messageDetailsBasic (pack $ show idac)
-- content <-

authorQuote :: Command
authorQuote = Command "author" (parseComm authorComm) []
  where
    authorComm ::
      WithError "Quote format incorrect!\nExpected author name to find quotes for after .quote author" (RestOfInput Text) ->
      Message ->
      DatabaseDiscord ()
    authorComm (WErr (ROI author)) m = authorQ author m >>= sendCustomMessage m

showQuote :: Command
showQuote = Command "show" (parseComm showComm) []
  where
    showComm ::
      WithError "Quote format incorrect!\nExpected quote number to show, e.g. .quote show 420" Int64 ->
      Message ->
      DatabaseDiscord ()
    showComm (WErr qId) m = showQ qId m >>= sendCustomMessage m

deleteQuote :: Command
deleteQuote = Command "delete" (parseComm deleteComm) []
  where
    deleteComm ::
      WithError "Quote format incorrect!\nExpected quote number to delete, e.g. .quote delete 420" Int64 ->
      Message ->
      DatabaseDiscord ()
    deleteComm (WErr qId) = deleteQ qId

randomQuote :: Command
randomQuote = Command "random" (parseComm randomComm) []
  where
    randomComm :: Message -> DatabaseDiscord ()
    randomComm m = randomQ m >>= sendCustomMessage m

-- | @showQuote@, which looks for a message of the form @!quote show n@, looks
-- that quote up in the database and responds with that quote.
showQ :: Context m => Int64 -> m -> DatabaseDiscord MessageDetails
showQ qId m = do
  qu <- get $ toSqlKey qId
  case qu of
    Just q -> renderQuoteMessage q qId m
    Nothing -> return $ messageDetailsBasic "Couldn't get that quote!"

-- | @randomQuote@, which looks for a message of the form @!quote random@,
-- selects a random quote from the database and responds with that quote.
randomQ :: Context m => m -> DatabaseDiscord MessageDetails
randomQ = filteredRandomQuote [] "Couldn't find any quotes!"

-- | @authorQuote@, which looks for a message of the form @!quote author u@,
-- selects a random quote from the database attributed to u and responds with that quote.
authorQ :: Context m => Text -> m -> DatabaseDiscord MessageDetails
authorQ t = filteredRandomQuote [QuoteAuthor ==. t] "Couldn't find any quotes with that author!"

-- | @filteredRandomQuote@ selects a random quote that meets a
-- given criteria, and returns that as the response, sending the user a message if the
-- quote cannot be found.
filteredRandomQuote :: Context m => [Filter Quote] -> Text -> m -> DatabaseDiscord MessageDetails
filteredRandomQuote quoteFilter errorMessage m = catchBot (filteredRandomQuote' quoteFilter errorMessage m) catchBot'
  where
    catchBot' (GenericException "quote exception" _) = return $ messageDetailsBasic errorMessage
    catchBot' e = throwBot e

-- | @filteredRandomQuote'@ selects a random quote that meets a
-- given criteria, and returns that as the response, throwing an exception if something
-- goes wrong.
filteredRandomQuote' :: Context m => [Filter Quote] -> Text -> m -> DatabaseDiscord MessageDetails
filteredRandomQuote' quoteFilter errorMessage m = do
  num <- count quoteFilter
  if num == 0
    then throwBot (GenericException "quote exception" (unpack errorMessage))
    else do
      rindex <- liftIO $ randomRIO (0, num - 1)
      key <- selectKeysList quoteFilter [OffsetBy rindex, LimitTo 1]
      qu <- get $ head key
      case qu of
        Just q -> renderQuoteMessage q (fromSqlKey $ head key) m
        Nothing -> throwBot (GenericException "quote exception" (unpack errorMessage))

-- | @addQuote@, which looks for a message of the form
-- @!quote add "quoted text" - author@, and then stores said quote in the
-- database, returning the ID used.
addQ :: Text -> Text -> Message -> DatabaseDiscord MessageDetails
addQ qu author m = addQ' qu author (toMention $ messageAuthor m) (messageId m) (messageChannelId m) m

addQ' :: Context m => Text -> Text -> Text -> MessageId -> ChannelId -> m -> DatabaseDiscord MessageDetails
addQ' qu author requestor sourceMsg sourceChannel m = do
  now <- liftIO $ systemToUTCTime <$> getSystemTime
  let new = Quote qu author requestor (fromIntegral sourceMsg) (fromIntegral sourceChannel) now
  added <- insert new
  let res = pack $ show $ fromSqlKey added
  renderCustomQuoteMessage ("Quote added as #" `append` res) new (fromSqlKey added) m

-- | @thisQuote@, which takes the replied message or the
-- previous message and stores said message as a quote in the database,
-- returning the ID used.
thisQ :: Message -> DatabaseDiscord ()
thisQ m = do
  q <- getReplyMessage m
  case q of
    (Just q') -> addMessageQuote (userId $ messageAuthor m) q' m >>= sendCustomMessage m
    Nothing -> do
      q2 <- getPrecedingMessage m
      case q2 of
        (Just q') -> addMessageQuote (userId $ messageAuthor m) q' m >>= sendCustomMessage m
        Nothing -> sendMessage m "Unable to add quote"

-- | @addMessageQuote@, adds a message as a quote to the database, checking that it passes the relevant tests
addMessageQuote :: Context m => UserId -> Message -> m -> DatabaseDiscord MessageDetails
addMessageQuote submitter q' m = do
  num <- count [QuoteMsgId ==. fromIntegral (messageId q')]
  if num == 0
    then
      if not $ userIsBot (messageAuthor q')
        then do
          now <- liftIO $ systemToUTCTime <$> getSystemTime
          let new =
                Quote
                  (messageContent q')
                  (toMention $ messageAuthor q')
                  (toMention' submitter)
                  (fromIntegral $ messageId q')
                  (fromIntegral $ messageChannelId q')
                  now
          added <- insert new
          let res = pack $ show $ fromSqlKey added
          renderCustomQuoteMessage ("Quote added as #" `append` res) new (fromSqlKey added) m
        else return $ messageDetailsBasic "Can't quote a bot"
    else return $ messageDetailsBasic "Message already quoted"

-- | @editQuote@, which looks for a message of the form
-- @!quote edit n "quoted text" - author@, and then updates quote with id n in the
-- database, to match the provided quote.
editQ :: Int64 -> Text -> Text -> Message -> DatabaseDiscord ()
editQ qId qu author m =
  requirePermission Any m $
    let k = toSqlKey qId
     in do
          oQu <- get k
          case oQu of
            Just Quote {} -> do
              now <- liftIO $ systemToUTCTime <$> getSystemTime
              let new = Quote qu author (toMention $ messageAuthor m) (fromIntegral $ messageId m) (fromIntegral $ messageChannelId m) now
              replace k new
              renderCustomQuoteMessage "Quote updated" new qId m >>= sendCustomMessage m
            Nothing -> sendMessage m "Couldn't update that quote!"

-- | @deleteQuote@, which looks for a message of the form @!quote delete n@,
-- and removes it from the database.
deleteQ :: Int64 -> Message -> DatabaseDiscord ()
deleteQ qId m =
  requirePermission Any m $
    let k = toSqlKey qId
     in do
          qu <- get k
          case qu of
            Just Quote {} -> do
              delete k
              sendMessage m "Quote deleted"
            Nothing -> sendMessage m "Couldn't delete that quote!"

renderQuoteMessage :: Context m => Quote -> Int64 -> m -> DatabaseDiscord MessageDetails
renderQuoteMessage = renderCustomQuoteMessage ""

renderCustomQuoteMessage :: Context m => Text -> Quote -> Int64 -> m -> DatabaseDiscord MessageDetails
renderCustomQuoteMessage t (Quote txt author submitter msgId cnlId dtm) qId m = do
  guild <- contextGuildId m
  let link = getLink guild
  return
    ( (messageDetailsBasic t)
        { messageDetailsEmbeds =
            Just
              [ addColour DiscordColorBlue $
                  addTimestamp dtm $
                    addFooter (pack $ "Quote #" ++ show qId) $
                      simpleEmbed (txt <> "\n - " <> author <> maybeAddFooter link)
              ]
        }
    )
  where
    getLink :: Maybe GuildId -> Maybe Text
    getLink = fmap (\x -> getMessageLink x (fromIntegral cnlId) (fromIntegral msgId))
    maybeAddFooter :: Maybe Text -> Text
    maybeAddFooter (Just l) = "\n[source](" <> l <> ") - added by " <> submitter
    maybeAddFooter Nothing = ""

showQuoteHelp :: HelpPage
showQuoteHelp =
  HelpPage
    "show"
    []
    "show a quote by number"
    "**Show Quote**\nShows a quote by id\n\n*Usage:* `quote show <id>`"
    []
    None

randomQuoteHelp :: HelpPage
randomQuoteHelp =
  HelpPage
    "random"
    []
    "show a random quote"
    "**Random Quote**\nDisplays a random quote\n\n*Usage:* `quote random`"
    []
    None

authorQuoteHelp :: HelpPage
authorQuoteHelp =
  HelpPage
    "user"
    []
    "show a random quote by a user"
    "**Random User Quote**\nDisplays a random quote attributed to a particular user\n\n*Usage:* `quote user <author>`"
    []
    Superuser

thisQuoteHelp :: HelpPage
thisQuoteHelp =
  HelpPage
    "this"
    []
    "add another message as a quote"
    [r|**Quote This Message**
Adds an existing message as a quote. If the command is a reply, it uses the replied to message, otherwise it uses the immediatly preceding message.

*Usage:* `quote this`|]
    []
    None

deleteQuoteHelp :: HelpPage
deleteQuoteHelp =
  HelpPage
    "delete"
    []
    "delete a quote by number"
    [r|**Delete Quote**
Delete a quote by id
Requires moderation permission

*Usage:* `quote delete <id>`|]
    []
    Any

editQuoteHelp :: HelpPage
editQuoteHelp =
  HelpPage
    "edit"
    []
    "edit a quote by number"
    [r|**Edit Quote**
Edit a quote by id
Requires moderation permission

*Usage:* `quote edit <id> "quote" - author`|]
    []
    Any

addQuoteHelp :: HelpPage
addQuoteHelp = HelpPage "add" [] "add a new quote" "**Add Quote**\nAdds a quote\n\n*Usage:* `quote add \"quote\" - author`" [] None

quoteHelp :: HelpPage
quoteHelp =
  HelpPage
    "quote"
    ["q"]
    "store and retrieve quotes"
    [r|**Quotes**
Allows storing and retrieving quotes.
Calling without arguments returns a random quote. Calling with a number returns that quote number. Calling with a mention or name gives a random quote by that person.

*Usage:* `quote` or `q`|]
    [randomQuoteHelp, showQuoteHelp, authorQuoteHelp, addQuoteHelp, thisQuoteHelp, editQuoteHelp, deleteQuoteHelp]
    None

-- | @quotePlugin@ assembles the @quote@ command (consisting of @add@ and
-- @show@) and the database migration into a plugin.
quotePlugin :: Plugin
quotePlugin =
  (plug "quote")
    { commands = [quoteCommand, commandAlias "q" quoteCommand],
      onReactionAdds = [quoteReactionAdd],
      migrations = [quoteMigration],
      helpPages = [quoteHelp],
      applicationCommands = catMaybes [quoteMessageAppComm]
    }

deriving instance Generic Quote

instance FromJSON Quote

instance ToJSON Quote

-- | Get all the quotes in the database.
allQuotes :: DatabaseDiscord [Quote]
allQuotes = fmap entityVal <$> selectList [] []

-- | Export all the quotes in the database to either a default quotes file or to a given
-- file name that is quoted in the command. Superuser only.
exportQuotes :: Command
exportQuotes = Command "export" (parseComm exportQ) []

exportQ :: Maybe (Quoted FilePath) -> Message -> DatabaseDiscord ()
exportQ qfp m = requirePermission Superuser m $ do
  let defFileName = getSystemTime >>= \now -> return $ "quotes_" <> show (systemSeconds now) <> ".json"
  (Qu fp) <- liftIO $ maybe (Qu <$> defFileName) return qfp
  aq <- allQuotes
  _ <- liftIO $ encodeFile fp aq
  sendMessage m ("Succesfully exported all " <> (pack . show . length) aq <> " quotes to `" <> pack fp <> "`")

-- | Import all the quotes in a file into the database from a given file. Superuser only.
importQuotes :: Command
importQuotes = Command "import" (parseComm importQ) []
  where
    importQ :: Quoted FilePath -> Message -> DatabaseDiscord ()
    importQ (Qu fp) m = requirePermission Superuser m $ do
      mqs <- liftIO $ decodeFileStrict fp
      qs <- maybe (throwBot $ GenericException "error getting file" "there was an error obtaining or decoding the quotes json") (insertMany @Quote) mqs
      sendMessage m ("Succesfully imported " <> (pack . show . length) qs <> " quotes")

-- | Clear all the quotes from the database. Superuser only.
clearQuotes :: Command
clearQuotes = Command "clear" (parseComm clearQ) []
  where
    clearQ :: Maybe (Quoted Text) -> Message -> DatabaseDiscord ()
    clearQ (Just (Qu "clear the quotes")) m = requirePermission Superuser m $ do
      exportQ Nothing m
      i <- deleteWhereCount @Quote []
      sendMessage m ("Cleared " <> pack (show i) <> " quotes from the database.")
    clearQ _ m = sendMessage m "To _really do this_, call this command like so: `quote clear \"clear the quotes\"`"

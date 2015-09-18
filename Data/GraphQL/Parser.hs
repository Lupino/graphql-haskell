{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module Data.GraphQL.Parser where

import Prelude hiding (takeWhile)

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>), (<*>), (*>), (<*), (<$), pure)
import Data.Monoid (Monoid, mempty)
#endif
import Control.Applicative ((<|>), empty, many, optional)
import Control.Monad (when)
import Data.Char
import Data.Text (Text, append)
import Data.Attoparsec.Text
  ( Parser
  , (<?>)
  , anyChar
  , decimal
  , double
  , endOfLine
  , inClass
  , many1
  , manyTill
  , option
  , peekChar
  , sepBy1
  , signed
  , takeWhile
  , takeWhile1
  )

import Data.GraphQL.AST

-- * Name

name :: Parser Name
name = tok $ append <$> takeWhile1 isA_z
                    <*> takeWhile ((||) <$> isDigit <*> isA_z)
  where
    -- `isAlpha` handles many more Unicode Chars
    isA_z =  inClass $ '_' : ['A'..'Z'] ++ ['a'..'z']


-- * Document

document :: Parser Document
document = whiteSpace
     *> (Document <$> many1 definition)
    -- Try SelectionSet when no definition
    <|> (Document . pure
                  . DefinitionOperation
                  . Query mempty empty empty
                <$> selectionSet)
    <?> "document error!"

definition :: Parser Definition
definition = DefinitionOperation <$> operationDefinition
         <|> DefinitionFragment  <$> fragmentDefinition
         <|> DefinitionType      <$> typeDefinition
         <?> "definition error!"

operationDefinition :: Parser OperationDefinition
operationDefinition =
        op Query "query"
    <|> op Mutation "mutation"
    <?> "operationDefinition error!"
  where
    op f n = f <$ tok n <*> tok name
                        <*> optempty variableDefinitions
                        <*> optempty directives
                        <*> selectionSet

variableDefinitions :: Parser [VariableDefinition]
variableDefinitions = parens (many1 variableDefinition)

variableDefinition :: Parser VariableDefinition
variableDefinition =
    VariableDefinition <$> variable
                       <*  tok ":"
                       <*> type_
                       <*> optional defaultValue

defaultValue :: Parser DefaultValue
defaultValue = tok "=" *> value

variable :: Parser Variable
variable = Variable <$ tok "$" <*> name

selectionSet :: Parser SelectionSet
selectionSet = braces $ many1 selection

selection :: Parser Selection
selection = SelectionField <$> field
            -- Inline first to catch `on` case
        <|> SelectionInlineFragment <$> inlineFragment
        <|> SelectionFragmentSpread <$> fragmentSpread
        <?> "selection error!"

field :: Parser Field
field = Field <$> optempty alias
              <*> name
              <*> optempty arguments
              <*> optempty directives
              <*> optempty selectionSet

alias :: Parser Alias
alias = name <* tok ":"

arguments :: Parser [Argument]
arguments = parens $ many1 argument

argument :: Parser Argument
argument = Argument <$> name <* tok ":" <*> value

-- * Fragments

fragmentSpread :: Parser FragmentSpread
-- TODO: Make sure it fails when `... on`.
-- See https://facebook.github.io/graphql/#FragmentSpread
fragmentSpread = FragmentSpread
    <$  tok "..."
    <*> name
    <*> optempty directives

-- InlineFragment tried first in order to guard against 'on' keyword
inlineFragment :: Parser InlineFragment
inlineFragment = InlineFragment
    <$  tok "..."
    <*  tok "on"
    <*> typeCondition
    <*> optempty directives
    <*> selectionSet

fragmentDefinition :: Parser FragmentDefinition
fragmentDefinition = FragmentDefinition
    <$  tok "fragment"
    <*> name
    <*  tok "on"
    <*> typeCondition
    <*> optempty directives
    <*> selectionSet

typeCondition :: Parser TypeCondition
typeCondition = namedType

-- * Values

-- This will try to pick the first type it can parse. If you are working with
-- explicit types use the `typedValue` parser.
value :: Parser Value
value = ValueVariable <$> variable
    -- TODO: Handle maxBound, Int32 in spec.
    <|> ValueInt      <$> tok (signed decimal)
    <|> ValueFloat    <$> tok (signed double)
    <|> ValueBoolean  <$> bool
    -- TODO: Handle escape characters, unicode, etc
    <|> ValueString   <$> quotes name
    -- `true` and `false` have been tried before
    <|> ValueEnum     <$> name
    <|> ValueList     <$> listValue
    <|> ValueObject   <$> objectValue

-- Notice it can be empty
listValue :: Parser ListValue
listValue = ListValue <$> brackets (many value)

-- Notice it can be empty
objectValue :: Parser ObjectValue
objectValue = ObjectValue <$> braces (many objectField)

objectField :: Parser ObjectField
objectField = ObjectField <$> name <* tok ":" <*> value

bool :: Parser Bool
bool = True  <$ tok "true"
   <|> False <$ tok "false"

-- * Directives

directives :: Parser [Directive]
directives = many1 directive

directive :: Parser Directive
directive = Directive
    <$  tok "@"
    <*> name
    <*> optempty arguments

-- * Type Reference

type_ :: Parser Type
type_ = TypeNamed   <$> namedType
    <|> TypeList    <$> listType
    <|> TypeNonNull <$> nonNullType

namedType :: Parser NamedType
namedType = NamedType <$> name

listType :: Parser ListType
listType = ListType <$> brackets type_

nonNullType :: Parser NonNullType
nonNullType = NonNullTypeNamed <$> namedType <* tok "!"
          <|> NonNullTypeList  <$> listType  <* tok "!"

-- * Type Definition

typeDefinition :: Parser TypeDefinition
typeDefinition =
        TypeDefinitionObject        <$> objectTypeDefinition
    <|> TypeDefinitionInterface     <$> interfaceTypeDefinition
    <|> TypeDefinitionUnion         <$> unionTypeDefinition
    <|> TypeDefinitionScalar        <$> scalarTypeDefinition
    <|> TypeDefinitionEnum          <$> enumTypeDefinition
    <|> TypeDefinitionInputObject   <$> inputObjectTypeDefinition
    <|> TypeDefinitionTypeExtension <$> typeExtensionDefinition
    <?> "typeDefinition error!"

objectTypeDefinition :: Parser ObjectTypeDefinition
objectTypeDefinition = ObjectTypeDefinition
    <$  tok "type"
    <*> name
    <*> optempty interfaces
    <*> fieldDefinitions
    <?> "objectTypeDefinition error!"

interfaces :: Parser Interfaces
interfaces = tok "implements" *> many1 namedType

fieldDefinitions :: Parser [FieldDefinition]
fieldDefinitions = braces $ many1 fieldDefinition

fieldDefinition :: Parser FieldDefinition
fieldDefinition = FieldDefinition
    <$> name
    <*> optempty argumentsDefinition
    <*  tok ":"
    <*> type_

argumentsDefinition :: Parser ArgumentsDefinition
argumentsDefinition = inputValueDefinitions

inputValueDefinitions :: Parser [InputValueDefinition]
inputValueDefinitions = parens $ many1 inputValueDefinition

inputValueDefinition :: Parser InputValueDefinition
inputValueDefinition = InputValueDefinition
    <$> name
    <*  tok ":"
    <*> type_
    <*> optional defaultValue

interfaceTypeDefinition :: Parser InterfaceTypeDefinition
interfaceTypeDefinition = InterfaceTypeDefinition
    <$  tok "interface"
    <*> name
    <*> fieldDefinitions

unionTypeDefinition :: Parser UnionTypeDefinition
unionTypeDefinition = UnionTypeDefinition
    <$  tok "union"
    <*> name
    <*  tok "="
    <*> unionMembers

unionMembers :: Parser [NamedType]
unionMembers = namedType `sepBy1` tok "|"

scalarTypeDefinition :: Parser ScalarTypeDefinition
scalarTypeDefinition = ScalarTypeDefinition
    <$  tok "scalar"
    <*> name

enumTypeDefinition :: Parser EnumTypeDefinition
enumTypeDefinition = EnumTypeDefinition
    <$  tok "enum"
    <*> name
    <*> enumValueDefinitions

enumValueDefinitions :: Parser [EnumValueDefinition]
enumValueDefinitions = braces $ many1 enumValueDefinition

enumValueDefinition :: Parser EnumValueDefinition
enumValueDefinition = EnumValueDefinition <$> name

inputObjectTypeDefinition :: Parser InputObjectTypeDefinition
inputObjectTypeDefinition = InputObjectTypeDefinition
    <$  tok "input"
    <*> name
    <*> inputValueDefinitions

typeExtensionDefinition :: Parser TypeExtensionDefinition
typeExtensionDefinition = TypeExtensionDefinition
    <$  tok "extend"
    <*> objectTypeDefinition

-- * Internal

tok :: Parser a -> Parser a
tok p = p <* whiteSpace

parens :: Parser a -> Parser a
parens = between "(" ")"

braces :: Parser a -> Parser a
braces = between "{" "}"

quotes :: Parser a -> Parser a
quotes = between "\"" "\""

brackets :: Parser a -> Parser a
brackets = between "[" "]"

between :: Parser Text -> Parser Text -> Parser a -> Parser a
between open close p = tok open *> p <* tok close

-- `empty` /= `pure mempty` for `Parser`.
optempty :: Monoid a => Parser a -> Parser a
optempty = option mempty

-- ** WhiteSpace
--
whiteSpace :: Parser ()
whiteSpace = peekChar >>= \case
    Just c -> if isSpace c || c == ','
              then anyChar *> whiteSpace
              else when (c == '#') $ manyTill anyChar endOfLine *> whiteSpace
    _ -> return ()

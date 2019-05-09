//
//  Parser.cpp
//  yo
//
//  Created by Lukas Kollmer on 2019-03-03.
//  Copyright © 2019 Lukas Kollmer. All rights reserved.
//

// NOTE: Most (all?) of this is crap and will be rewritten eventually, once i know how parsers are actually supposed to work (ideally some time after passing theo and/or cc?)

#include "Parser.h"

#include <string>
#include <vector>
#include <map>
#include <array>
#include <fstream>
#include <sstream>
#include "Mangling.h"
#include "StdlibResolution.h"

using namespace yo;
using namespace yo::ast;
using namespace yo::parser;

using TK = Token::TokenKind;

#pragma mark - Parser Utils

#define assert_current_token(Expected) \
do { if (auto T = CurrentToken(); T.Kind != Expected) { \
    auto &S = T.SourceLocation; \
    std::cout << "[token assert] Expected: " << Expected << ", got: " << T.Kind << ". (file: " << S.Filename << ":" << S.Line << ":" << S.Column << ")\n";  \
    throw; \
} } while (0)

#define assert_current_token_and_consume(Expected) \
do { if (auto T = CurrentToken(); T.Kind != Expected) { \
    auto &S = T.SourceLocation; \
    std::cout << "[token assert] Expected: " << Expected << ", got: " << T.Kind << ". (file: " << S.Filename << ":" << S.Line << ":" << S.Column << ")\n";  \
    throw; \
} else { Consume(); } } while (0)

#define unhandled_token(T)                                                                                                      \
{                                                                                                                               \
    auto &SL = T.SourceLocation;                                                                                                \
    std::cout << "Unhandled Token: " << T << " at " << SL.Filename << ":" << SL.Line << ":" << SL.Column << std::endl; throw;   \
}


class TokenSet {
    std::vector<TK> Tokens;
    
public:
    TokenSet(std::initializer_list<TK> Tokens) : Tokens(Tokens) {}
    
    bool Contains(TK Token) {
        return util::vector::contains(Tokens, Token);
    }
};


template <typename T>
class MappedTokenSet {
    std::map<TK, T> Mapping;
    
public:
    MappedTokenSet(std::initializer_list<std::pair<TK, T>> Mapping) {
        for (auto &Pair : Mapping) {
            this->Mapping.insert(Pair);
        }
    }
    
    bool Contains(TK Token) {
        return Mapping.find(Token) != Mapping.end();
    }
    
    T &operator [](TK Token) {
        return Mapping.at(Token);
    }
};



#pragma mark - Token Collections

// The initial tokens of all binary operators (binops, comparisons, etc)
static TokenSet BinaryOperatorStartTokens = {
    TK::Plus, TK::Minus, TK::Asterisk, TK::ForwardSlash, TK::PercentageSign,
    TK::Ampersand, TK::Pipe, TK::Circumflex, TK::LessThanSign, TK::GreaterSign,
    TK::EqualsSign, TK::ExclamationMark
};



static MappedTokenSet<ast::BinaryOperation::Operation> SingleTokenBinopOperatorTokenMapping = {
    { TK::Plus,           BinaryOperation::Operation::Add },
    { TK::Minus,          BinaryOperation::Operation::Sub },
    { TK::Asterisk,       BinaryOperation::Operation::Mul },
    { TK::ForwardSlash,   BinaryOperation::Operation::Div },
    { TK::PercentageSign, BinaryOperation::Operation::Mod },
    { TK::Ampersand,      BinaryOperation::Operation::And },
    { TK::Pipe,           BinaryOperation::Operation::Or  },
    { TK::Circumflex,     BinaryOperation::Operation::Xor }
};




#pragma mark - Parser


#define save_pos(name) auto name = Position;
#define restore_pos(name) Position = name;

// How does the parser work?
//
// Position always points to the current token.
// For example, if we parse an identifier, after returning from `ParseIdentifier`, Position would point to the token after that identifier


TokenList LexFile(std::string &Path) {
    std::ifstream File(Path);
    std::ostringstream Contents;
    Contents << File.rdbuf();
    File.close();

    return Lexer().Lex(Contents.str(), Path);
}


AST Parser::Parse(std::string &FilePath) {
    this->Position = 0;
    this->Tokens = LexFile(FilePath);
    ImportedFiles.push_back(FilePath);
    
    AST Ast;
    while (Position < Tokens.size() && CurrentTokenKind() != TK::EOF_) {
        Ast.push_back(ParseTopLevelStmt());
    }
    
    return Ast;
}


#include <sys/stat.h>
namespace fs {
    bool file_exists(std::string &Path) {
        struct stat S;
        return stat(Path.c_str(), &S) == 0;
    }
}


// TODO move the entire module resolution stuff somewhere else !?
std::string Parser::ResolveImportPathRelativeToBaseDirectory(const std::string &ModuleName, const std::string &BaseDirectory) {
    if (ModuleName[0] == '/') { // absolute path
        return ModuleName;
    }
    
    std::string Path = std::string(BaseDirectory).append("/").append(ModuleName).append(".yo");
    if (fs::file_exists(Path)) return Path;
    
    LKFatalError("Unable to resolve import of '%s' relative to '%s'", ModuleName.c_str(), BaseDirectory.c_str());
}



void Parser::ResolveImport() {
    auto BaseDirectory = util::string::excludingLastPathComponent(CurrentToken().SourceLocation.Filename);
    assert_current_token_and_consume(TK::Use);
    
    auto ModuleName = ParseStringLiteral()->Value;
    assert_current_token_and_consume(TK::Semicolon);
    
    TokenList NewTokens;
    
    if (ModuleName[0] == ':') { // stdlib import
        if (util::vector::contains(ImportedFiles, ModuleName)) return;
        ImportedFiles.push_back(ModuleName);
        NewTokens = Lexer().Lex(stdlib_resolution::GetContentsOfModuleWithName(ModuleName), ModuleName);
    } else {
        std::string Path = ResolveImportPathRelativeToBaseDirectory(ModuleName, BaseDirectory);
        if (util::vector::contains(ImportedFiles, Path)) return;
        ImportedFiles.push_back(Path);
        NewTokens = LexFile(Path);
    }
    
    Tokens.insert(Tokens.begin() + Position,
                  NewTokens.begin(),
                  NewTokens.end() - 1); // exclude EOF_
}




std::shared_ptr<TopLevelStmt> Parser::ParseTopLevelStmt() {
    std::shared_ptr<TopLevelStmt> Stmt;
    auto attributeList = ParseAttributes();
    
    switch (CurrentToken().Kind) {
        case TK::Fn: {
            auto F = ParseFunctionDecl();
            F->Signature->Kind = ast::FunctionSignature::FunctionKind::GlobalFunction;
            F->Signature->attributes = std::make_shared<attributes::FunctionAttributes>(attributeList);
            Stmt = F;
            break;
        }
        case TK::Extern: {
            auto F = ParseExternFunctionDecl();
            F->Signature->Kind = ast::FunctionSignature::FunctionKind::GlobalFunction;
            F->Signature->attributes = std::make_shared<attributes::FunctionAttributes>(attributeList);
            Stmt = F;
            break;
        }
        case TK::Struct: {
            auto S = ParseStructDecl();
            S->attributes = std::make_shared<attributes::StructAttributes>(attributeList);
            Stmt = S;
            break;
        }
        case TK::Impl:
            Stmt = ParseImplBlock();
            break;
        case TK::Use:
            ResolveImport(); // TODO can/should imports have annotations?
            return ParseTopLevelStmt();
        case TK::Using:
            Stmt = ParseTypealias();
            break;
        default: unhandled_token(CurrentToken());
    }
    return Stmt;
}


std::shared_ptr<StructDecl> Parser::ParseStructDecl() {
    assert_current_token_and_consume(TK::Struct);
    
    auto Decl = std::make_shared<StructDecl>();
    Decl->Name = ParseIdentifier();
    
    if (CurrentTokenKind() == TK::LessThanSign) {
        Consume();
        while (CurrentTokenKind() != TK::GreaterSign) {
            Decl->TemplateArguments.push_back(ParseIdentifier()->Value);
            if (CurrentTokenKind() == TK::Comma) Consume();
        }
        assert_current_token_and_consume(TK::GreaterSign);
    }
    assert_current_token_and_consume(TK::OpeningCurlyBraces);
    
    Decl->Members = ParseParameterList();
    assert_current_token_and_consume(TK::ClosingCurlyBraces);
    return Decl;
}


std::shared_ptr<ImplBlock> Parser::ParseImplBlock() {
    assert_current_token_and_consume(TK::Impl);
    
    auto impl = std::make_shared<ImplBlock>(ParseIdentifier()->Value);
    assert_current_token_and_consume(TK::OpeningCurlyBraces);
    
    while (CurrentTokenKind() == TK::Fn) {
        auto functionDecl = ParseFunctionDecl();
        functionDecl->Signature->attributes = std::make_shared<yo::attributes::FunctionAttributes>();
        impl->Methods.push_back(functionDecl);
    }
    
    assert_current_token_and_consume(TK::ClosingCurlyBraces);
    return impl;
}


std::vector<yo::attributes::Attribute> Parser::ParseAttributes() {
    if (CurrentTokenKind() != TK::Hashtag) return {};
    Consume();
    assert_current_token_and_consume(TK::OpeningSquareBrackets);
    
    std::vector<yo::attributes::Attribute> attributes;
    
    
    while (auto Ident = ParseIdentifier()) {
        auto key = Ident->Value;
        
        if (CurrentTokenKind() == TK::OpeningParens) {
            Consume();
            std::vector<std::string> members;
            while (auto Ident = ParseIdentifier()) {
                members.push_back(Ident->Value);
                if (CurrentTokenKind() == TK::Comma) {
                    Consume();
                } else if (CurrentTokenKind() == TK::ClosingParens) {
                    break;
                } else {
                    unhandled_token(CurrentToken());
                }
            }
            assert_current_token_and_consume(TK::ClosingParens);
            attributes.push_back(yo::attributes::Attribute(key, members));
        } else {
            attributes.push_back(yo::attributes::Attribute(key));
        }

        if (CurrentTokenKind() == TK::Comma) {
            Consume();
            assert_current_token(TK::Identifier); // Comma must be followed by another attribute
            continue;
        } else if (CurrentTokenKind() == TK::ClosingSquareBrackets) {
            Consume();
            if (CurrentTokenKind() == TK::Hashtag && PeekKind() == TK::OpeningSquareBrackets) {
                Consume(2);
                continue;
            } else {
                break;
            }
        }
    }
    
    return attributes;
}



std::shared_ptr<FunctionSignature> Parser::ParseFunctionSignature(bool IsExternal) {
    assert_current_token_and_consume(TK::Fn);
    
    auto S = std::make_shared<ast::FunctionSignature>();
    S->Name = ParseIdentifier()->Value;
    
    if (CurrentTokenKind() == TK::LessThanSign) { // Template function
        S->IsTemplateFunction = true;
        Consume();
        while (CurrentTokenKind() != TK::GreaterSign) {
            S->TemplateArgumentNames.push_back(ParseIdentifier()->Value);
            if (CurrentTokenKind() == TK::Comma) Consume();
        }
        assert_current_token_and_consume(TK::GreaterSign);
    }
    assert_current_token_and_consume(TK::OpeningParens);
    
    if (!IsExternal) {
        S->Parameters = ParseParameterList();
    } else {
        S->Parameters = {};
        while (CurrentTokenKind() != TK::ClosingParens) {
            S->Parameters.push_back(std::make_shared<VariableDecl>(ast::Identifier::emptyIdent(), ParseType()));
            if (CurrentTokenKind() == TK::Comma) Consume();
        }
    }
    assert_current_token_and_consume(TK::ClosingParens);
    
    if (CurrentTokenKind() == TK::Colon) {
        Consume();
        S->ReturnType = ParseType();
    } else {
        S->ReturnType = TypeInfo::Void;
    }
    
    return S;
}



std::shared_ptr<ExternFunctionDecl> Parser::ParseExternFunctionDecl() {
    assert_current_token_and_consume(TK::Extern);
    
    auto EFD = std::make_shared<ExternFunctionDecl>();
    EFD->Signature = ParseFunctionSignature(true);
    
    assert_current_token_and_consume(TK::Semicolon);
    return EFD;
}

std::shared_ptr<FunctionDecl> Parser::ParseFunctionDecl() {
    auto FD = std::make_shared<FunctionDecl>();
    FD->Signature = ParseFunctionSignature(false);
    assert_current_token(TK::OpeningCurlyBraces);
    
    FD->Body = ParseComposite();
    return FD;
}





std::vector<std::shared_ptr<VariableDecl>> Parser::ParseParameterList() {
    std::vector<std::shared_ptr<VariableDecl>> Parameters;
    
    while (CurrentTokenKind() == TK::Identifier) {
        auto Ident = ParseIdentifier();
        assert_current_token_and_consume(TK::Colon);
        
        auto Type = ParseType();
        Parameters.push_back(std::make_shared<VariableDecl>(Ident, Type));
        
        if (CurrentTokenKind() == TK::Comma) {
            Consume();
        } else {
            break;
        }
    }
    
    return Parameters;
}


TypeInfo *Parser::ParseType() {
    if (CurrentTokenKind() == TK::Fn) {
        Consume();
        TypeInfo::FunctionTypeInfo::CallingConvention cc;
        if (CurrentTokenKind() == TK::Hashtag) {
            Consume();
            auto cc_ident = ParseIdentifier();
            if (cc_ident->Value == "c") {
                cc = TypeInfo::FunctionTypeInfo::CallingConvention::C;
            } else if (cc_ident->Value == "yo") {
                cc = TypeInfo::FunctionTypeInfo::CallingConvention::Yo;
            } else {
                LKFatalError("unknown calling convention: %s", cc_ident->Value.c_str());
            }
        }
        assert_current_token_and_consume(TK::OpeningParens);
        // TODO delegate this to ParseFunctionSignature? (w/ extern set to true and maybe some other option that disables the function name?)
        
        std::vector<TypeInfo *> parameterTypes;
        while (auto T = ParseType()) {
            parameterTypes.push_back(T);
            if (CurrentTokenKind() == TK::Comma) {
                Consume(); continue;
            } else if (CurrentTokenKind() == TK::ClosingParens) {
                Consume(); break;
            } else {
                unhandled_token(CurrentToken());
            }
        }
        assert_current_token_and_consume(TK::Colon);
        auto returnType = ParseType();
        
        return TypeInfo::MakeFunctionType(cc, parameterTypes, returnType);
        
    }
    
    if (CurrentTokenKind() == TK::Identifier) {
        auto Name = ParseIdentifier()->Value;
        return TypeInfo::GetWithName(Name);
    }
    
    if (CurrentTokenKind() == TK::Asterisk) {
        Consume();
        return ParseType()->getPointerTo();
    }
    
    return nullptr;
}



std::shared_ptr<ast::TypealiasDecl> Parser::ParseTypealias() {
    assert_current_token_and_consume(TK::Using);
    auto Name = ParseIdentifier()->Value;
    assert_current_token_and_consume(TK::EqualsSign);
    auto Type = ParseType();
    assert_current_token_and_consume(TK::Semicolon);
    return std::make_shared<TypealiasDecl>(Name, Type);
}



#pragma mark - Local Statements



std::shared_ptr<Composite> Parser::ParseComposite() {
    assert_current_token_and_consume(TK::OpeningCurlyBraces);
    
    auto C = std::make_shared<Composite>();
    while (CurrentTokenKind() != TK::ClosingCurlyBraces) {
        C->Statements.push_back(ParseLocalStmt());
    }
    
    assert_current_token_and_consume(TK::ClosingCurlyBraces);
    return C;
}






std::shared_ptr<LocalStmt> Parser::ParseLocalStmt() {
    if (CurrentTokenKind() == TK::Return) {
        return ParseReturnStmt();
    }
    
    if (CurrentTokenKind() == TK::Let) {
        return ParseVariableDecl();
    }
    
    if (CurrentTokenKind() == TK::If) {
        return ParseIfStmt();
    }
    
    if (CurrentTokenKind() == TK::While) {
        return ParseWhileStmt();
    }
    
    if (CurrentTokenKind() == TK::For) {
        return ParseForLoop();
    }
    
    std::shared_ptr<LocalStmt> S;
    std::shared_ptr<Expr> E; // A partially-parsed part of a local statement
    
    //E = ParseMemberAccess();
    E = ParseExpression();
    
    if (CurrentTokenKind() == TK::EqualsSign) { // Assignment
        Consume();
        auto Value = ParseExpression();
        assert_current_token_and_consume(TK::Semicolon);
        
        return std::make_shared<Assignment>(E, Value);
    }
    
    if (BinaryOperatorStartTokens.Contains(CurrentTokenKind())) {
        if (auto Op = ParseBinopOperator()) {
            assert_current_token_and_consume(TK::EqualsSign);
            
            auto Value = std::make_shared<BinaryOperation>(*Op, E, ParseExpression());
            S = std::make_shared<Assignment>(E, Value);
            assert_current_token_and_consume(TK::Semicolon);
            return S;
        }
    }
    
    if (CurrentTokenKind() == TK::Semicolon) {
        Consume();
        if (E) {
            return std::make_shared<ast::NEW_ExprStmt>(E);
        }
    }
    
    unhandled_token(CurrentToken())
}



std::shared_ptr<ReturnStmt> Parser::ParseReturnStmt() {
    assert_current_token_and_consume(TK::Return);
    
    if (CurrentTokenKind() == TK::Semicolon) {
        Consume();
        return std::make_shared<ReturnStmt>(nullptr);
    }
    
    auto Expr = ParseExpression();
    assert_current_token_and_consume(TK::Semicolon);
    return std::make_shared<ReturnStmt>(Expr);
}



std::shared_ptr<VariableDecl> Parser::ParseVariableDecl() {
    assert_current_token_and_consume(TK::Let);
    
    auto Identifier = ParseIdentifier();
    auto Type = TypeInfo::Unresolved;
    std::shared_ptr<Expr> InitialValue;
    
    if (CurrentTokenKind() == TK::Colon) {
        Consume();
        Type = ParseType();
    }
    
    if (CurrentTokenKind() == TK::EqualsSign) {
        Consume();
        InitialValue = ParseExpression();
    }
    
    assert_current_token_and_consume(TK::Semicolon);
    
    return std::make_shared<VariableDecl>(Identifier, Type, InitialValue);
}



std::shared_ptr<IfStmt> Parser::ParseIfStmt() {
    using Kind = ast::IfStmt::Branch::BranchKind;
    assert_current_token_and_consume(TK::If);
    
    std::vector<std::shared_ptr<IfStmt::Branch>> Branches;
    
    auto MainExpr = ParseExpression();
    assert_current_token(TK::OpeningCurlyBraces);
    
    Branches.push_back(std::make_shared<IfStmt::Branch>(Kind::If,
                                                        MainExpr,
                                                        ParseComposite()));
    
    while (CurrentTokenKind() == TK::Else && PeekKind() == TK::If) {
        Consume(2);
        auto Expr = ParseExpression();
        assert_current_token(TK::OpeningCurlyBraces);
        auto Body = ParseComposite();
        Branches.push_back(std::make_shared<IfStmt::Branch>(Kind::ElseIf, Expr, Body));
    }
    
    if (CurrentTokenKind() == TK::Else && PeekKind() == TK::OpeningCurlyBraces) {
        Consume();
        Branches.push_back(std::make_shared<IfStmt::Branch>(Kind::Else, nullptr, ParseComposite()));
    }
    
    return std::make_shared<IfStmt>(Branches);
}




std::shared_ptr<ast::WhileStmt> Parser::ParseWhileStmt() {
    assert_current_token_and_consume(TK::While);
    
    auto Condition = ParseExpression();
    assert_current_token(TK::OpeningCurlyBraces);
    
    return std::make_shared<ast::WhileStmt>(Condition, ParseComposite());
}



std::shared_ptr<ForLoop> Parser::ParseForLoop() {
    assert_current_token_and_consume(TK::For);
    auto Ident = ParseIdentifier();
    assert_current_token_and_consume(TK::In);
    auto Expr = ParseExpression();
    assert_current_token(TK::OpeningCurlyBraces);
    auto Body = ParseComposite();
    return std::make_shared<ForLoop>(Ident, Expr, Body);
}



#pragma mark - Expressions



// Parses a (potentially empty) list of expressions separated by commas, until Delimiter is reached
// The delimiter is not consumed
std::vector<std::shared_ptr<Expr>> Parser::ParseExpressionList(Token::TokenKind Delimiter) {
    if (CurrentTokenKind() == Delimiter) return {};
    
    std::vector<std::shared_ptr<Expr>> Expressions;
    
    do {
        Expressions.push_back(ParseExpression());
        precondition(CurrentTokenKind() == TK::Comma || CurrentTokenKind() == Delimiter);
        if (CurrentTokenKind() == TK::Comma) Consume();
    } while (CurrentTokenKind() != Delimiter);
    
    assert_current_token(Delimiter);
    return Expressions;
}



std::shared_ptr<Identifier> Parser::ParseIdentifier() {
    if (CurrentTokenKind() != TK::Identifier) return nullptr;
    auto value = std::get<std::string>(CurrentToken().Data);
    auto retval = std::make_shared<Identifier>(value);
    Consume();
    return retval;
}

        
std::optional<ast::BinaryOperation::Operation> Parser::ParseBinopOperator() {
    auto T = CurrentTokenKind();
    if (!BinaryOperatorStartTokens.Contains(T)) throw;
    
    if (SingleTokenBinopOperatorTokenMapping.Contains(T)) {
        Consume();
        return SingleTokenBinopOperatorTokenMapping[T];
    }
    
    if (T == TK::LessThanSign && PeekKind() == TK::LessThanSign) {
        Consume(2);
        return BinaryOperation::Operation::Shl;
    }
    
    if (T == TK::GreaterSign && PeekKind() == TK::GreaterSign) {
        Consume(2);
        return BinaryOperation::Operation::Shr;
    }
    
    return std::nullopt;
}


std::optional<ast::Comparison::Operation> Parser::ParseComparisonOperator() {
    using Op = ast::Comparison::Operation;
    
    auto Token = CurrentTokenKind();
    if (!BinaryOperatorStartTokens.Contains(Token)) throw;
    
    auto Next = PeekKind();
    
    if (Token == TK::EqualsSign && Next == TK::EqualsSign) {
        Consume(2); return Op::EQ;
    }
    
    if (Token == TK::ExclamationMark && Next == TK::EqualsSign) {
        Consume(2); return Op::NE;
    }
    
    if (Token == TK::LessThanSign && Next == TK::EqualsSign) {
        Consume(2); return Op::LE;
    }
    
    if (Token == TK::LessThanSign) {
        Consume(); return Op::LT;
    }
    
    if (Token == TK::GreaterSign && Next == TK::EqualsSign) {
        Consume(2); return Op::GE;
    }
    
    if (Token == TK::GreaterSign) {
        Consume(); return Op::GT;
    }
    
    return std::nullopt;
}


std::optional<ast::LogicalOperation::Operation> Parser::ParseLogicalOperationOperator() {
    auto Token = CurrentTokenKind();
    if (!BinaryOperatorStartTokens.Contains(Token)) throw;
    
    auto Next = PeekKind();
    
    if (Token == TK::Ampersand && Next == TK::Ampersand) {
        Consume(2); return ast::LogicalOperation::Operation::And;
    }
    if (Token == TK::Pipe && Next == TK::Pipe) {
        Consume(2); return ast::LogicalOperation::Operation::Or;
    }
    
    return std::nullopt;
}


PrecedenceGroup GetOperatorPrecedenceGroup(BinaryOperation::Operation Op) {
    switch (Op) {
    case BinaryOperation::Operation::Add:
    case BinaryOperation::Operation::Sub:
    case BinaryOperation::Operation::Or:
    case BinaryOperation::Operation::Xor:
        return PrecedenceGroup::Addition;
    case BinaryOperation::Operation::Mul:
    case BinaryOperation::Operation::Div:
    case BinaryOperation::Operation::Mod:
    case BinaryOperation::Operation::And:
        return PrecedenceGroup::Multiplication;
    case BinaryOperation::Operation::Shl:
    case BinaryOperation::Operation::Shr:
        return PrecedenceGroup::Bitshift;
    }
    throw;
}


PrecedenceGroup GetOperatorPrecedenceGroup(ast::Comparison::Operation) {
    return PrecedenceGroup::Comparison;
}

PrecedenceGroup GetOperatorPrecedenceGroup(ast::LogicalOperation::Operation Op) {
    switch (Op) {
        case LogicalOperation::Operation::And: return PrecedenceGroup::LogicalConjunction;
        case LogicalOperation::Operation::Or:  return PrecedenceGroup::LogicalDisjunction;
    }
}


// Tokens that, if they appear on their own, mark the end of an expression
static TokenSet ExpressionDelimitingTokens = {
    TK::ClosingParens, TK::Semicolon, TK::Comma, TK::OpeningCurlyBraces, TK::ClosingSquareBrackets, TK::EqualsSign, TK::ClosingCurlyBraces
};


std::shared_ptr<Expr> Parser::ParseExpression(PrecedenceGroup PrecedenceGroupConstraint) {
    if (ExpressionDelimitingTokens.Contains(CurrentTokenKind())) {
        return nullptr;
    }
    
    std::shared_ptr<Expr> E;
    
    if (CurrentTokenKind() == TK::OpeningParens) {
        Consume();
        E = ParseExpression();
        assert_current_token_and_consume(TK::ClosingParens);
    
    } if (CurrentTokenKind() == TK::Match) {
        E = ParseMatchExpr();
    }
    
    if (!E) {
        E = ParseNumberLiteral();
    }
    
    if (!E) {
        E = ParseUnaryExpr();
    }
    
    if (!E) {
        E = ParseStringLiteral();
    }
    
    if (!E) {
        E = ParseIdentifier();
        
        if (CurrentTokenKind() == TK::Colon && PeekKind() == TK::Colon) {
            // a static member reference
            // Q: how do we know that for sure?
            // A: we only end up here if E was null before -> the ident and the two colons are at the beginning of the expression we're parsing
            
            auto typeName = std::dynamic_pointer_cast<ast::Identifier>(E)->Value;
            Consume(2);
            auto memberName = ParseIdentifier()->Value;
            E = std::make_shared<ast::NEW_StaticDeclRefExpr>(typeName, memberName);
        }
    }
    
    
    ast::Expr *_last_entry_expr_ptr = nullptr;
    
    while (true) {
        precondition(E);
        if (_last_entry_expr_ptr == E.get()) {
            unhandled_token(CurrentToken());
        }
        _last_entry_expr_ptr = E.get();
        
        if (ExpressionDelimitingTokens.Contains(CurrentTokenKind())) {
            if (CurrentTokenKind() == TK::EqualsSign && PeekKind() == TK::EqualsSign) {
                goto parse_binop_expr;
            }
            return E;
        }
        
        // Q: What's going on here?
        // A: Basically, the idea is to catch all tokens that might indicate what kind of expression this is (call, member, binop, comparison, etc)
        //    in this big while loop
        // Q: What kinds of expressions are handled in here?
        // A: Everything that isn't the "initial" part of an expression (that's why E has to be nunnull on entry)
        // Q: How does this work, being a loop?
        // A: We return from the loop when encountering something that doesn't belong to the current precedence group
        // The long term plan is splitting this up in a bunch of functions and having ParseExpression call them from the while loop, depending on which kind of expression seems most likely based on the current token
        
//    parse_call_expr:
        if (CurrentTokenKind() == TK::LessThanSign || CurrentTokenKind() == TK::OpeningParens) {
            if (auto callExpr = ParseCallExpr(E)) {
                E = callExpr;
                continue; // TODO is the consume actually required/good?
            } else if (CurrentTokenKind() == TK::LessThanSign) {
                goto parse_binop_expr; // use this as a hint that this is probably a binop expression?
            }
        }
        
        
        
//    parse_member_expr:
        if (CurrentTokenKind() == TK::Period) { // member expr
            Consume();
            auto memberName = ParseIdentifier()->Value;
            E = std::make_shared<ast::MemberExpr>(E, memberName);
            // TODO goto parse_call_expr if the current token is `<` or `(`?
            // member expressions are probably somewhat often also call targets?
        }
        
        
        
//    parse_subscript_expr:
        if (CurrentTokenKind() == TK::OpeningSquareBrackets) {
            Consume();
            auto offsetExpr = ParseExpression();
            assert_current_token_and_consume(TK::ClosingSquareBrackets);
            E = std::make_shared<ast::SubscriptExpr>(E, offsetExpr);
        }
        
        
        
    parse_binop_expr:
        if (BinaryOperatorStartTokens.Contains(CurrentTokenKind())) {
            // TODO should thid be a while loop? not really necessary since it's already embedded in a while loop but it might be useful (doesn't have to run all other token comparisons first, before reaching here)?
            save_pos(fallback);
            
            // Since there are multitple binary operators starting with the same initial token (`|` vs `||`, `<` vs `<<`, etc),
            // it's important we parse the different kinds of binary operators in the correct order
            
            if (auto op = ParseLogicalOperationOperator()) {
                auto op_precedence = GetOperatorPrecedenceGroup(*op);
                if (op_precedence >= PrecedenceGroupConstraint) {
                    auto rhs = ParseExpression(op_precedence);
                    E = std::make_shared<LogicalOperation>(*op, E, rhs);
                } else {
                    restore_pos(fallback);
                    return E;
                }
            } else if (CurrentTokenKind() == TK::Pipe && PeekKind() == TK::GreaterSign) { // `|>` {
                // TODO allow functions w/ explicit template arguments
                // ie: `return argv[1] |> atoi |> static_cast<i64> |> fib;`
                
                if (PrecedenceGroupConstraint >= PrecedenceGroup::FunctionPipeline) {
                    return E;
                }
                
                Consume(2);
                auto callTarget = ParseExpression(PrecedenceGroup::FunctionPipeline);
                E = std::make_shared<ast::CallExpr>(callTarget, std::vector<std::shared_ptr<ast::Expr>>{ E });
                continue;
                
            } else if (auto op = ParseBinopOperator()) {
                if (CurrentTokenKind() == TK::EqualsSign) {
                    // <expr> <op>= <expr>;
                    restore_pos(fallback);
                    return E;
                }
                auto op_precedence = GetOperatorPrecedenceGroup(*op);
                if (op_precedence >= PrecedenceGroupConstraint) {
                    auto rhs = ParseExpression(op_precedence);
                    E = std::make_shared<ast::BinaryOperation>(*op, E, rhs);
                } else {
                    restore_pos(fallback);
                    return E;
                }
            } else if (auto op = ParseComparisonOperator()) {
                // TODO take the precedence group constraint into account? might be needed for expressions like `1 < x < 2`?
                auto rhs = ParseExpression(PrecedenceGroup::Comparison);
                E = std::make_shared<ast::Comparison>(*op, E, rhs);
            } else {
                // We reach here if the current token is a binary operator starting token, but we didn't manage to parse anything valid out of it
                continue;
            }
        }
        
    } // end ParseExpression main while loop
    
    LKFatalError("should never reach here");
}







std::shared_ptr<ast::CallExpr> Parser::ParseCallExpr(std::shared_ptr<ast::Expr> target) {
    std::vector<TypeInfo *> explicitTemplateArgumentTypes;
    
    if (CurrentTokenKind() == TK::LessThanSign) {
        save_pos(pos_of_less_than_sign);
        Consume();
        while (CurrentTokenKind() != TK::GreaterSign) { // TODO this might become a problem if there is an `<>` operator?
            auto type = ParseType();
            if (!type) {
                restore_pos(pos_of_less_than_sign);
                return nullptr;
            }
            explicitTemplateArgumentTypes.push_back(type);
            
            if (CurrentTokenKind() == TK::Comma) {
                Consume(); continue;
            } else if (CurrentTokenKind() == TK::GreaterSign) {
                break;
            } else {
                // If we end up here, the less than sign is probably part of a comparison or bit shift
                restore_pos(pos_of_less_than_sign);
                return nullptr;
            }
        }
        assert_current_token_and_consume(TK::GreaterSign);
        precondition(!explicitTemplateArgumentTypes.empty()); // TODO allow empty explicit template lists?
    }
    assert_current_token_and_consume(TK::OpeningParens);
    
    auto callArguments = ParseExpressionList(TK::ClosingParens);
    assert_current_token_and_consume(TK::ClosingParens);
    return std::make_shared<ast::CallExpr>(target, callArguments, explicitTemplateArgumentTypes);
}





static TokenSet MemberAccessSeparatingTokens = {
    TK::LessThanSign, TK::OpeningParens, TK::OpeningSquareBrackets, TK::Period, TK::Colon
};




std::shared_ptr<ast::MatchExpr> Parser::ParseMatchExpr() {
    assert_current_token_and_consume(TK::Match);
    auto Target = ParseExpression();
    assert_current_token_and_consume(TK::OpeningCurlyBraces);
    std::vector<std::shared_ptr<ast::MatchExpr::MatchExprBranch>> Branches;
    
    while (true) {
        auto Patterns = ParseExpressionList(TK::EqualsSign);
        assert_current_token_and_consume(TK::EqualsSign);
        assert_current_token_and_consume(TK::GreaterSign);
        auto Expr = ParseExpression();
        Branches.push_back(std::make_shared<ast::MatchExpr::MatchExprBranch>(Patterns, Expr));
        
        switch (CurrentTokenKind()) {
            case TK::Comma:
                Consume();
                continue;
            case TK::ClosingCurlyBraces:
                goto ret;
            default:
                unhandled_token(CurrentToken());
        }
    }
ret:
    assert_current_token_and_consume(TK::ClosingCurlyBraces);
    return std::make_shared<ast::MatchExpr>(Target, Branches);
}





// MARK: Literals


std::shared_ptr<NumberLiteral> Parser::ParseNumberLiteral() {
    uint64_t Value;
    NumberLiteral::NumberType Type;
    bool IsNegated = false;
    
    save_pos(prev_pos)
    
    if (CurrentTokenKind() == TK::Minus) {
        Consume();
        IsNegated = true;
    }
    
    switch (CurrentTokenKind()) {
        case TK::IntegerLiteral:
            Value = std::get<uint64_t>(CurrentToken().Data);
            Type = NumberLiteral::NumberType::Integer;
            break;
        case TK::DoubleLiteral: throw;
        case TK::CharLiteral:
            Value = std::get<char>(CurrentToken().Data);
            Type = NumberLiteral::NumberType::Character;
            break;
        case TK::BoolLiteral:
            Value = std::get<bool>(CurrentToken().Data);
            Type = NumberLiteral::NumberType::Boolean;
            break;
        default:
            restore_pos(prev_pos);
            return nullptr;
    }
    Consume();
    
    if (IsNegated) {
        Value *= -1;
    }
    return std::make_shared<NumberLiteral>(Value, Type);
}




std::shared_ptr<StringLiteral> Parser::ParseStringLiteral() {
    auto &T = CurrentToken();
    
    if (T.Kind != TK::StringLiteral && T.Kind != TK::ByteStringLiteral) {
        return nullptr;
    }
    
    auto value = std::get<std::string>(T.Data);
    auto kind = T.Kind == TK::StringLiteral
        ? StringLiteral::StringLiteralKind::NormalString
        : StringLiteral::StringLiteralKind::ByteString;
    
    Consume();
    return std::make_shared<StringLiteral>(value, kind);
}


static MappedTokenSet<ast::UnaryExpr::Operation> UnaryOperators = {
    { TK::Minus, UnaryExpr::Operation::Negate },
    { TK::Tilde, UnaryExpr::Operation::BitwiseNot },
    { TK::ExclamationMark, UnaryExpr::Operation::LogicalNegation}
};

std::shared_ptr<UnaryExpr> Parser::ParseUnaryExpr() {
    if (!UnaryOperators.Contains(CurrentTokenKind())) return nullptr;
    auto Op = UnaryOperators[CurrentTokenKind()];
    Consume();
    auto Expr = ParseExpression(PrecedenceGroup::PrefixOperator);
    return std::make_shared<UnaryExpr>(Op, Expr);
}

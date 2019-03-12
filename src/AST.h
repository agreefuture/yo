//
//  AST.h
//  yo
//
//  Created by Lukas Kollmer on 2019-03-03.
//  Copyright © 2019 Lukas Kollmer. All rights reserved.
//

#pragma once

#include <memory>
#include <iostream>

#include "util.h"
#include "TypeInfo.h"

NS_START(ast)


class TopLevelStmt;

using AST = std::vector<std::shared_ptr<TopLevelStmt>>;


std::string Description(AST &Ast);


class Expr;
class Identifier;
class VariableDecl;
class Composite;


class Node {
public:
    virtual std::string Description();
    
protected:
    Node() {}
    virtual ~Node() = default;
};



class TopLevelStmt : virtual public Node {};

class LocalStmt : virtual public Node {};

class Expr : virtual public Node {};





#pragma mark - Top Level Statements



class FunctionSignature {
public:
    enum class FunctionKind {
        GlobalFunction,   // A free global function
        StaticMethod,     // A static type member method
        InstanceMethod    // A type instance method
    };
    
    std::string Name; // TODO make this an identifier?
    FunctionKind Kind;
    std::vector<std::shared_ptr<VariableDecl>> Parameters;
    TypeInfo *ReturnType;
};



class FunctionDecl : public TopLevelStmt, public FunctionSignature {
public:
    std::shared_ptr<Composite> Body;
    
    FunctionDecl() : FunctionSignature() {}
};


class ExternFunctionDecl : public TopLevelStmt, public FunctionSignature {
public:
    ExternFunctionDecl() : FunctionSignature() {}
};


class StructDecl : public TopLevelStmt {
public:
    std::shared_ptr<Identifier> Name;
    std::vector<std::shared_ptr<VariableDecl>> Attributes;
    
    StructDecl(std::shared_ptr<Identifier> Name, std::vector<std::shared_ptr<VariableDecl>> Attributes) : Name(Name), Attributes(Attributes) {}
};

class ImplBlock : public TopLevelStmt {
public:
    std::string Typename;
    std::vector<std::shared_ptr<FunctionDecl>> Methods;
    
    ImplBlock(std::string Typename) : Typename(Typename) {}
    ImplBlock(std::string Typename, std::vector<std::shared_ptr<FunctionDecl>> Methods) : Typename(Typename), Methods(Methods) {}
};



# pragma mark - Local Statements


class Composite : public LocalStmt {
public:
    std::vector<std::shared_ptr<LocalStmt>> Statements;
    
    Composite() {}
};


class ReturnStmt : public LocalStmt {
public:
    std::shared_ptr<Expr> Expression;
    
    explicit ReturnStmt(std::shared_ptr<Expr> Expression) : Expression(Expression) {}
};



class VariableDecl : public LocalStmt {
public:
    std::shared_ptr<Identifier> Name; // TODO does something like this really warrant a pointer?
    TypeInfo *Type;
    std::shared_ptr<Expr> InitialValue;
    
    VariableDecl(std::shared_ptr<Identifier> Name, TypeInfo *Type, std::shared_ptr<Expr> InitialValue = nullptr)
    : Name(Name), Type(Type), InitialValue(InitialValue) {}
};


class Assignment : public LocalStmt {
public:
    std::shared_ptr<Expr> Target;
    std::shared_ptr<Expr> Value;
    
    Assignment(std::shared_ptr<Expr> Target, std::shared_ptr<Expr> Value) : Target(Target), Value(Value) {}
};



class IfStmt : public LocalStmt {
public:
    class Branch : public Node { // Sole purpose of making this inherit from Node is simplifying ast dumping
    public:
        enum class BranchKind {
            If, ElseIf, Else
        };
        
        BranchKind Kind;
        std::shared_ptr<Expr> Condition; // nullptr if Kind == BranchKind::Else
        std::shared_ptr<Composite> Body;
        
        Branch(BranchKind Kind, std::shared_ptr<Expr> Condition, std::shared_ptr<Composite> Body)
        : Kind(Kind), Condition(Condition), Body(Body) {}
    };
    
    std::vector<std::shared_ptr<Branch>> Branches;
    
    IfStmt(std::vector<std::shared_ptr<Branch>> Branches) : Branches(Branches) {}
};








# pragma mark - Expressions


class Identifier : public Expr {
public:
    const std::string Value;
    Identifier(std::string Value) : Value(Value) {}
    
    operator std::string () { return Value; }
};



class NumberLiteral : public Expr {
public:
    uint64_t Value;
    
    explicit NumberLiteral(uint64_t Value) : Value(Value) {}
};


class StringLiteral : public Expr {
public:
    std::string Value;
    
    explicit StringLiteral(std::string Value) : Value(Value) {}
};


class CharLiteral : public Expr {
public:
    char Value;
    
    explicit CharLiteral(char Value) : Value(Value) {}
};



class FunctionCall : public Expr {
public:
    std::shared_ptr<Expr> Target;
    std::vector<std::shared_ptr<Expr>> Arguments;
    bool UnusedReturnValue;
    
    FunctionCall(std::shared_ptr<Expr> Target, std::vector<std::shared_ptr<Expr>> Arguments, bool UnusedReturnValue)
    : Target(Target), Arguments(Arguments), UnusedReturnValue(UnusedReturnValue) {}
};



class Typecast : public Expr {
public:
    std::shared_ptr<Expr> Expression;
    TypeInfo *DestType;
    bool ForceBitcast;
    
    Typecast(std::shared_ptr<Expr> Expression, TypeInfo *DestType, bool ForceBitcast = false)
    : Expression(Expression), DestType(DestType), ForceBitcast(ForceBitcast) {}
};



// A (chained) member access
class MemberAccess : public Expr, public LocalStmt {
public:
    class Member : public Node { // same as IfStmt::Branch
    public:
        enum class MemberKind {
            Initial_Identifier,     // Value in Data.Ident
            Initial_FunctionCall,   // Value in Data.Call
            
            OffsetRead,             // Value in Data.Offset
            MemberFunctionCall,     // Value in Data.Call (call target is name of the method being called)
            MemberAttributeRead     // Value in Data.Ident
        };
        
        union MemberData {
            std::shared_ptr<Identifier> Ident;
            std::shared_ptr<FunctionCall> Call;
            std::shared_ptr<Expr> Offset;
            
            // https://stackoverflow.com/a/40302092/2513803
            MemberData() : Ident{} {}
            ~MemberData() {}
        };
        
        MemberKind Kind;
        MemberData Data;
        
        Member(MemberKind Kind) : Kind(Kind) {}
        Member(MemberKind Kind, std::shared_ptr<Identifier> Ident) : Kind(Kind) {
            precondition(Kind == MemberKind::Initial_Identifier || Kind == MemberKind::MemberAttributeRead);
            Data.Ident = Ident;
        }
        Member(MemberKind Kind, std::shared_ptr<FunctionCall> Call) : Kind(Kind) {
            precondition(Kind == MemberKind::Initial_FunctionCall || Kind == MemberKind::MemberFunctionCall);
            Data.Call = Call;
        }
        Member(MemberKind Kind, std::shared_ptr<Expr> Offset) : Kind(Kind) {
            precondition(Kind == MemberKind::OffsetRead);
            Data.Offset = Offset;
        }
        ~Member();
    };
    
    std::vector<std::shared_ptr<Member>> Members;
    
    MemberAccess(std::vector<std::shared_ptr<Member>> Members) : Members(Members) {}
};



//
//class PointerRead : public Expr {
//public:
//    std::shared_ptr<Expr> Target;
//    std::shared_ptr<Expr> Offset;
//
//    PointerRead(std::shared_ptr<Expr> Target, std::shared_ptr<Expr> Offset) : Target(Target), Offset(Offset) {}
//};


class BinaryOperation : public Expr {
public:
    enum class Operation {
        Add, Sub, Mul, Div, Mod,
        And, Or, Xor, Shl, Shr
    };
    
    Operation Op;
    std::shared_ptr<Expr> LHS;
    std::shared_ptr<Expr> RHS;
    
    BinaryOperation(Operation Op, std::shared_ptr<Expr> LHS, std::shared_ptr<Expr> RHS) : Op(Op), LHS(LHS), RHS(RHS) {}
};



class Comparison : public Expr {
public:
    enum class Operation {
        EQ, NE, // == / !=
        LT, LE, // > \ >=
        GT, GE  // < \ <=
    };
    
    Operation Op;
    std::shared_ptr<Expr> LHS;
    std::shared_ptr<Expr> RHS;
    
    Comparison(Operation Op, std::shared_ptr<Expr> LHS, std::shared_ptr<Expr> RHS) : Op(Op), LHS(LHS), RHS(RHS) {}
};


class LogicalOperation : public Expr {
public:
    enum class Operation {
        And, Or
    };
    
    Operation Op;
    std::shared_ptr<Expr> LHS;
    std::shared_ptr<Expr> RHS;
    
    LogicalOperation(Operation Op, std::shared_ptr<Expr> LHS, std::shared_ptr<Expr> RHS) : Op(Op), LHS(LHS), RHS(RHS) {}
};

NS_END

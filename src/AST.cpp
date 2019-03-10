//
//  AST.cpp
//  yo
//
//  Created by Lukas Kollmer on 2019-03-03.
//  Copyright © 2019 Lukas Kollmer. All rights reserved.
//

#include "AST.h"

#include <string>
#include <iostream>
#include <ostream>
#include <sstream>
#include <strstream>
#include <map>



// TODO
// Some node kinds always fit on a single line (identifiers, numbers, maybe some other literals?). Implement that!



using namespace ast;

std::string FunctionKindToString(FunctionSignature::FunctionKind Kind) {
    switch (Kind) {
    case FunctionSignature::FunctionKind::Global:   return "global";
    case FunctionSignature::FunctionKind::Static:   return "static";
    case FunctionSignature::FunctionKind::Instance: return "instance";
    }
}

std::string BinopOperationToString(BinaryOperation::Operation Op) {
    switch (Op) {
    case BinaryOperation::Operation::Add: return "add";
    case BinaryOperation::Operation::Sub: return "sub";
    case BinaryOperation::Operation::Mul: return "mul";
    case BinaryOperation::Operation::Div: return "div";
    case BinaryOperation::Operation::Mod: return "mod";
    case BinaryOperation::Operation::And: return "and";
    case BinaryOperation::Operation::Or:  return "or";
    case BinaryOperation::Operation::Xor: return "xor";
    case BinaryOperation::Operation::Shl: return "shl";
    case BinaryOperation::Operation::Shr: return "shr";
    }
}


std::string ComparisonOpToString(Comparison::Operation Op) {
    switch (Op) {
    case ast::Comparison::Operation::EQ: return  "eq";
    case ast::Comparison::Operation::NE: return  "ne";
    case ast::Comparison::Operation::LT: return  "lt";
    case ast::Comparison::Operation::LE: return  "le";
    case ast::Comparison::Operation::GT: return  "gt";
    case ast::Comparison::Operation::GE: return  "ge";
    }
}


std::string LogicalOperationOperatorToString(LogicalOperation::Operation Op) {
    switch (Op) {
        case LogicalOperation::Operation::And: return "and";
        case LogicalOperation::Operation::Or:  return "or";
    }
}


std::string IfStmtBranchKindToString(IfStmt::Branch::BranchKind Kind) {
    switch (Kind) {
        case ast::IfStmt::Branch::BranchKind::If:     return "if";
        case ast::IfStmt::Branch::BranchKind::ElseIf: return "else if";
        case ast::IfStmt::Branch::BranchKind::Else:   return "else";
    }
}


//
//std::string NodeKindToString(Node::NodeKind Kind) {
//#define CASE(x) case K::x: return "ast::"#x;
//    using K = Node::NodeKind;
//    switch (Kind) {
//    case K::Node:
//    case K::Expr:
//    case K::Stmt:
//    case K::TopLevelStmt:
//        throw;
//    CASE(LocalStmt)
//    CASE(FunctionDecl)
//    CASE(ReturnStmt)
//    CASE(Composite)
//    CASE(VariableDecl)
//    CASE(NumberLiteral)
//    CASE(StringLiteral)
//    CASE(ArrayLiteral)
//    CASE(Identifier)
//    CASE(ExternFunctionDecl)
//    CASE(FunctionCall)
//    CASE(BinaryOperation)
//    CASE(Comparison)
//            CASE(Log)
//    }
//#undef CASE
//}




inline constexpr unsigned INDENT_SIZE = 2;



template <typename T>
std::string ast_description(std::vector<std::shared_ptr<T>> _Nodes) {
    std::vector<std::shared_ptr<T>> Nodes(_Nodes.begin(), _Nodes.end());
    
    std::string Desc;
    Desc += "std::vector<";
    Desc += util::typeinfo::LKTypeInfo<T>::Name;
    Desc += "> [\n";
    
    for (auto It = Nodes.begin(); It != Nodes.end(); It++) {
        util::string::append_with_indentation(Desc,
                                              *It ? (*It)->Description() : "<nullptr>",
                                              INDENT_SIZE);
        
        if (It + 1 != Nodes.end()) {
            Desc += ",";
        }
        Desc += "\n";
    }
    Desc += "]";
    
    return Desc;
}


std::string ast::Description(AST &Ast) {
    return ast_description(Ast);
}



template <typename T>
std::string to_string(T arg) {
    if constexpr(std::is_same_v<T, const char *>) {
        return std::string(arg);
    } else if constexpr(std::is_base_of_v<std::string, T>) {
        return arg;
    } else if constexpr(std::is_integral_v<T>) {
        return std::to_string(arg);
    } else if constexpr(std::is_same_v<T, TypeInfo *>) {
        return arg->Str();
    } else if constexpr(std::is_same_v<T, FunctionSignature::FunctionKind>) {
        return FunctionKindToString(arg);
    } else if constexpr(std::is_same_v<T, BinaryOperation::Operation>) {
        return BinopOperationToString(arg);
    } else if constexpr(std::is_same_v<T, Comparison::Operation>) {
        return ComparisonOpToString(arg);
    } else if constexpr(std::is_same_v<T, LogicalOperation::Operation>) {
        return LogicalOperationOperatorToString(arg);
    } else if constexpr(std::is_same_v<T, IfStmt::Branch::BranchKind>) {
        return IfStmtBranchKindToString(arg);
    } else if constexpr(std::is_convertible_v<T, std::shared_ptr<Node>>) {
        if (!arg) return "<nullptr>";
        return arg->Description();
    } else if constexpr(util::typeinfo::is_vector_of_convertible_v<T, std::shared_ptr<Node>>) {
        return ast_description(arg);
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-value"
        // Sole purpose of this cast is getting a compiler warning that includes the specific type of `T`
        static_cast<std::nullptr_t>(arg);
#pragma clang diagnostic push
        throw;
    }
}






struct AttributeDescription {
    const std::string Key;
    const std::string Value;
    
    template <typename T>
    AttributeDescription(const std::string Key, T Value) : Key(Key), Value(to_string(Value)) {}
};

using Mirror = std::vector<AttributeDescription>;


Mirror Reflect(FunctionSignature *Signature) {
    return {
        { "name", Signature->Name },
        { "kind", Signature->Kind },
        { "returnType", Signature->ReturnType },
    };
}

Mirror Reflect(ExternFunctionDecl *EFD) {
    return Reflect(static_cast<FunctionSignature *>(EFD));
}

Mirror Reflect(FunctionDecl *FD) {
    auto M = Reflect(static_cast<FunctionSignature *>(FD));
    M.push_back({ "body", FD->Body });
    return M;
}

Mirror Reflect(Composite *C) {
    return {
        { "body", C->Statements }
    };
}

Mirror Reflect(ReturnStmt *Return) {
    return {
        { "expr", Return->Expression }
    };
}

Mirror Reflect(NumberLiteral *Number) {
    return {
        { "value", Number->Value }
    };
}

Mirror Reflect(Identifier *Ident) {
    return {
        { "value", Ident->Value }
    };
}

Mirror Reflect(FunctionCall *Call) {
    return {
        { "Target", Call->Target },
        { "UnusedReturnValue", Call->UnusedReturnValue },
        { "Arguments", Call->Arguments }
    };
}

Mirror Reflect(BinaryOperation *Binop) {
    return {
        { "Op", Binop->Op },
        { "Lhs", Binop->LHS },
        { "Rhs", Binop->RHS }
    };
}

Mirror Reflect(VariableDecl *Decl) {
    return {
        { "name", Decl->Name },
        { "type", Decl->Type },
        { "initial value", Decl->InitialValue }
    };
}

Mirror Reflect(Comparison *Comp) {
    return {
        { "op", Comp->Op },
        { "lhs", Comp->LHS },
        { "rhs", Comp->RHS }
    };
}

Mirror Reflect(LogicalOperation *LogOp) {
    return {
        { "op", LogOp->Op },
        { "lhs", LogOp->LHS },
        { "rhs", LogOp->RHS }
    };
}

Mirror Reflect(IfStmt *If) {
    return {
        { "branches", If->Branches }
    };
}

Mirror Reflect(IfStmt::Branch *Branch) {
    return {
        { "kind", Branch->Kind },
        { "condition", Branch->Condition },
        { "body", Branch->Body },
    };
}

Mirror Reflect(Assignment *Assignment) {
    return {
        { "target", Assignment->Target },
        { "value", Assignment->Value }
    };
}

Mirror Reflect(Typecast *Cast) {
    return {
        { "type", Cast->DestType },
        { "expr", Cast->Expression }
    };
}

Mirror Reflect(Node *Node) {
#define HANDLE(T) if (auto X = dynamic_cast<T*>(Node)) return Reflect(X);
    
    HANDLE(FunctionDecl)
    HANDLE(Composite)
    HANDLE(ReturnStmt)
    HANDLE(NumberLiteral)
    HANDLE(ExternFunctionDecl)
    HANDLE(FunctionCall)
    HANDLE(Identifier)
    HANDLE(BinaryOperation)
    HANDLE(VariableDecl)
    HANDLE(Comparison)
    HANDLE(LogicalOperation)
    HANDLE(IfStmt)
    HANDLE(IfStmt::Branch)
    HANDLE(Assignment)
    HANDLE(Typecast)
    
    std::cout << "[Reflect] Unhandled Node: " << util::typeinfo::GetTypename(*Node) << std::endl;
    throw;

#undef HANDLE
}



std::string Node::Description() {
    std::string Desc;
    
    Desc.append(util::typeinfo::GetTypename(*this)).append(" [");
    auto M = Reflect(this);
    
    if (M.empty()) {
        return Desc + "]";
    }
    
    Desc += "\n";
    
    for (auto It = M.begin(); It != M.end(); It++) {
        auto &[Key, Value] = *It;
        util::string::append_with_indentation(Desc, Key + ": " + Value, INDENT_SIZE);
        
        if (It + 1 != M.end()) {
            Desc += ",";
        }
        Desc += "\n";
    }
    Desc += "]";
    
    return Desc;
}







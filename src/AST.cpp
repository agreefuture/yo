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


using namespace yo;
using namespace yo::ast;



#pragma mark - AST Printing

std::ostream& ast::operator<<(std::ostream &OS, const ast::FunctionSignature& signature) {
    if (signature.isTemplateFunction()) {
        OS << "<";
        for (auto it = signature.templateArgumentNames.begin(); it != signature.templateArgumentNames.end(); it++) {
            OS << *it;
            if (it + 1 != signature.templateArgumentNames.end()) {
                OS << ", ";
            }
        }
        OS << ">";
    }
    OS << "(";

    for (auto it = signature.parameters.begin(); it != signature.parameters.end(); it++) {
        OS << (*it)->type->str();
        if (it + 1 != signature.parameters.end()) {
            OS << ", ";
        }
    }
    OS << ") -> " << signature.returnType->str();
    return OS;
}


#define CASE(n) case E::n: return #n;

std::string FunctionKindToString(FunctionKind kind) {
    using E = FunctionKind;
    switch (kind) {
        CASE(GlobalFunction)
        CASE(StaticMethod)
        CASE(InstanceMethod)
        CASE(OperatorOverload)
    }
}



std::string IfStmtBranchKindToString(IfStmt::Branch::BranchKind kind) {
    using E = IfStmt::Branch::BranchKind;
    switch (kind) {
        CASE(If)
        CASE(ElseIf)
        CASE(Else)
    }
}


std::string StringLiteralKindToString(StringLiteral::StringLiteralKind kind) {
    using E = StringLiteral::StringLiteralKind;
    switch (kind) {
        CASE(NormalString)
        CASE(ByteString)
    }
}

std::string NumberTypeToString(NumberLiteral::NumberType type) {
    using E = NumberLiteral::NumberType;
    switch (type) {
        CASE(Integer)
        CASE(Double)
        CASE(Character)
        CASE(Boolean)
    }
}

std::string UnaryExprOpToString(UnaryExpr::Operation op) {
    using E = UnaryExpr::Operation;
    switch (op) {
        CASE(Negate)
        CASE(BitwiseNot)
        CASE(LogicalNegation)
    }
}


std::string operatorToString(ast::Operator op) {
    using E = ast::Operator;
    switch (op) {
        CASE(Add)
        CASE(Sub)
        CASE(Mul)
        CASE(Div)
        CASE(Mod)
        CASE(And)
        CASE(Or)
        CASE(Xor)
        CASE(Shl)
        CASE(Shr)
        CASE(Neg)
        CASE(BNot)
        CASE(BNeg)
        CASE(LAnd)
        CASE(LOr)
        CASE(EQ)
        CASE(NE)
        CASE(LT)
        CASE(LE)
        CASE(GT)
        CASE(GE)
        CASE(FnPipe)
        CASE(Assign)
    }
}

#undef CASE








inline constexpr unsigned INDENT_SIZE = 2;


// TODO somehow consolidate the two functions below. they're pretty much identical


template <typename T>
std::string ast_description(const std::vector<T>& nodes) {
    std::string desc;
    desc += "std::vector<";
    desc += util::typeinfo::TypeInfo<T>::name;
    desc += "> [\n";
    
    for (auto it = nodes.begin(); it != nodes.end(); it++) {
        util::string::append_with_indentation(desc, it->description(), INDENT_SIZE);
        if (it + 1 != nodes.end()) {
            desc += ",";
        }
        desc += "\n";
    }
    desc += "]";
    
    return desc;
}


template <typename T>
std::string ast_description(std::vector<std::shared_ptr<T>> nodes) {
    std::string desc;
    desc += "std::vector<";
    desc += util::typeinfo::TypeInfo<T>::name;
    desc += "> [\n";

    for (auto it = nodes.begin(); it != nodes.end(); it++) {
        util::string::append_with_indentation(desc,
                                              *it ? (*it)->description() : "<nullptr>",
                                              INDENT_SIZE);

        if (it + 1 != nodes.end()) {
            desc += ",";
        }
        desc += "\n";
    }
    desc += "]";

    return desc;
}


std::string ast::description(const AST& ast) {
    return ast_description(ast);
}



template <typename T>
std::string to_string(T arg) {
    if constexpr(std::is_pointer_v<T> || util::typeinfo::is_shared_ptr_v<T>) {
        if (!arg) return "<nullptr>";
    }
    
    if constexpr(std::is_same_v<T, const char *>) {
        return std::string(arg);
    
    } else if constexpr(std::is_base_of_v<std::string, T>) {
        return arg;
    
    } else if constexpr(std::is_integral_v<T>) {
        return std::to_string(arg);
    
    } else if constexpr(std::is_same_v<T, TypeDesc*> || std::is_convertible_v<T, std::shared_ptr<TypeDesc>>) {
        return arg->str();
        
    } else if constexpr(std::is_base_of_v<irgen::Type, typename std::remove_pointer_t<T>>) {
        return arg->str();
    
    } else if constexpr(std::is_same_v<T, FunctionKind>) {
        return FunctionKindToString(arg);
    
    } else if constexpr(std::is_same_v<T, IfStmt::Branch::BranchKind>) {
        return IfStmtBranchKindToString(arg);
    
    } else if constexpr(std::is_same_v<T, StringLiteral::StringLiteralKind>) {
        return StringLiteralKindToString(arg);
        
    } else if constexpr(std::is_same_v<T, NumberLiteral::NumberType>) {
        return NumberTypeToString(arg);
        
    } else if constexpr(std::is_same_v<T, UnaryExpr::Operation>) {
        return UnaryExprOpToString(arg);
        
    } else if constexpr(std::is_same_v<T, ast::Operator>) {
        return operatorToString(arg);
    
    } else if constexpr(std::is_convertible_v<T, std::shared_ptr<Node>> || (std::is_pointer_v<T> && std::is_base_of_v<Node, typename std::remove_pointer_t<T>>)) {
        return arg->description();
        
    } else if constexpr(std::is_convertible_v<T, const Node&>) {
        return arg.description();
        
    } else if constexpr(util::typeinfo::is_vector_of_convertible_v<T, std::shared_ptr<Node>>) {
        return ast_description(arg);
        
    } else if constexpr(util::typeinfo::is_vector_v<T> && std::is_base_of_v<Node, typename T::value_type>) {
        return ast_description(arg);
    
    } else {
        // this will always fail, but if it does, we get a nice compile-time error message which includes the typename of T
        static_assert(std::is_null_pointer_v<T>, "ugh");
        throw;
    }
}






struct AttributeDescription {
    const std::string key;
    const std::string value;
    
    template <typename T>
    AttributeDescription(const std::string key, T value) : key(key), value(to_string(value)) {}
};

using Mirror = std::vector<AttributeDescription>;


Mirror Reflect(const FunctionSignature* signature) {
    return {
        { "parameters", signature->parameters },
        { "returnType", signature->returnType },
        { "isVariadic", signature->isVariadic }
    };
}

Mirror Reflect(const FunctionDecl *FD) {
    return {
        { "funcKind", FD->getFunctionKind() },
        { "name", FD->getName() },
        { "signature", FD->getSignature() },
        //{ "attributes", FD->getAttributes() }, // TODO
        { "body", FD->getBody() },
        { "implType", FD->getImplType() }
    };
}

Mirror Reflect(const Composite *C) {
    return {
        { "body", C->statements }
    };
}

Mirror Reflect(const ReturnStmt *ret) {
    return {
        { "expr", ret->expression }
    };
}

Mirror Reflect(const NumberLiteral *number) {
    return {
        { "type", number->type },
        { "value", number->value }
    };
}

Mirror Reflect(const Ident *ident) {
    return {
        { "value", ident->value }
    };
}

Mirror Reflect(const VarDecl *decl) {
    return {
        { "name", decl->name },
        { "type", decl->type },
        { "initial value", decl->initialValue }
    };
}

Mirror Reflect(const IfStmt *If) {
    return {
        { "branches", If->branches },
    };
}

Mirror Reflect(const IfStmt::Branch *branch) {
    return {
        { "kind", branch->kind },
        { "condition", branch->condition },
        { "body", branch->body },
    };
}

Mirror Reflect(const Assignment *assignment) {
    return {
        { "target", assignment->target },
        { "value", assignment->value }
    };
}

Mirror Reflect(const CastExpr *cast) {
    return {
        { "type", cast->destType },
        { "expr", cast->expression }
    };
}


Mirror Reflect(const StructDecl *Struct) {
    return {
        { "name", Struct->name },
        { "members", Struct->members }
    };
}

Mirror Reflect(const ImplBlock *implBlock) {
    return {
        { "typename", implBlock->typename_ },
        { "methods", implBlock->methods }
    };
}

Mirror Reflect(const StringLiteral *SL) {
    return {
        { "kind", SL->kind },
        { "value", SL->value }
    };
}

Mirror Reflect(const UnaryExpr *unaryExpr) {
    return {
        { "operation", unaryExpr->op },
        { "expr", unaryExpr->expr }
    };
}

Mirror Reflect(const MatchExpr *matchExpr) {
    return {
        { "target", matchExpr->target },
        { "branches", matchExpr->branches }
    };
}

Mirror Reflect(const MatchExpr::MatchExprBranch *branch) {
    return {
        { "patterns", branch->patterns },
        { "expr", branch->expression }
    };
}

Mirror Reflect(const ast::CallExpr *callExpr) {
    std::string explicitTemplateArgumentTypes = "[ ";
    for (auto it = callExpr->explicitTemplateArgumentTypes.begin(); it != callExpr->explicitTemplateArgumentTypes.end(); it++) {
        explicitTemplateArgumentTypes.append((*it)->str());
        if (it + 1 != callExpr->explicitTemplateArgumentTypes.end()) {
            explicitTemplateArgumentTypes.append(", ");
        }
    }
    explicitTemplateArgumentTypes.append(" ]");
    
    return {
        { "target", callExpr->target },
        { "arguments", callExpr->arguments },
        { "explicitTemplateArgumentTypes", explicitTemplateArgumentTypes }
    };
}

Mirror Reflect(const ast::MemberExpr *memberExpr) {
    return {
        { "target", memberExpr->target },
        { "memberName", memberExpr->memberName }
    };
}

Mirror Reflect(const ast::StaticDeclRefExpr *staticDeclRefExpr) {
    return {
        { "typeName", staticDeclRefExpr->typeName },
        { "memberName", staticDeclRefExpr->memberName }
    };
}

Mirror Reflect(const ast::WhileStmt *whileStmt) {
    return {
        { "condition", whileStmt->condition },
        { "body", whileStmt->body },
    };
}

Mirror Reflect(const ast::SubscriptExpr *subscriptExpr) {
    return {
        { "target", subscriptExpr->target },
        { "offset", subscriptExpr->offset },
    };
}

Mirror Reflect(const ast::ExprStmt *exprStmt) {
    return {
        { "expr", exprStmt->expr }
    };
}

Mirror Reflect(const ast::TypealiasDecl *typealias) {
    return {
        { "name", typealias->typename_ },
        { "type", typealias->type }
    };
}

Mirror Reflect(const ast::BinOp *binop) {
    return {
        { "op", binop->getOperator() },
        { "lhs", binop->getLhs() },
        { "rhs", binop->getRhs() },
    };
}




Mirror Reflect(const Node *node) {
#define CASE(ty) case NK::ty: return Reflect(static_cast<const ty *>(node));
#define CASE2(c, ty) case NK::c: return Reflect(static_cast<const ty *>(node));
    using NK = Node::NodeKind;
    
    switch (node->getNodeKind()) {
        CASE(FunctionDecl)
        CASE(Composite)
        CASE(ReturnStmt)
        CASE(NumberLiteral)
        CASE(Ident)
        CASE(VarDecl)
        CASE(IfStmt)
        CASE2(IfStmtBranch, IfStmt::Branch)
        CASE(Assignment)
        CASE(CastExpr)
        CASE(StructDecl)
        CASE(ImplBlock)
        CASE(StringLiteral)
        CASE(FunctionSignature)
        CASE(UnaryExpr)
        CASE(MatchExpr)
        CASE2(MatchExprBranch, MatchExpr::MatchExprBranch)
        CASE(CallExpr)
        CASE(MemberExpr)
        CASE(StaticDeclRefExpr)
        CASE(WhileStmt)
        CASE(SubscriptExpr)
        CASE(ExprStmt)
        CASE(TypealiasDecl)
        CASE(BinOp)
        default:
            std::cout << "[Reflect] Unhandled Node: " << util::typeinfo::getTypename(*node) << std::endl;
            LKFatalError("");
    }
#undef CASE2
#undef CASE
}



std::string Node::description() const {
    std::string desc;
    
    desc.append(util::typeinfo::getTypename(*this)).append(" [");
    auto M = Reflect(this);
    
    if (M.empty()) {
        return desc + "]";
    }
    
    desc += "\n";
    
    for (auto it = M.begin(); it != M.end(); it++) {
        const auto& [key, value] = *it;
        util::string::append_with_indentation(desc, key + ": " + value, INDENT_SIZE);
        
        if (it + 1 != M.end()) {
            desc += ",";
        }
        desc += "\n";
    }
    desc += "]";
    
    return desc;
}







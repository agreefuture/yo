//
//  Mangling.h
//  yo
//
//  Created by Lukas Kollmer on 2019-03-01.
//  Copyright © 2019 Lukas Kollmer. All rights reserved.
//

#include <string>
#include <memory>
#include "AST.h"

namespace yo::mangling {
    std::string mangleFullyResolvedNameForSignature(std::shared_ptr<ast::FunctionSignature>);
    std::string mangleCanonicalNameForSignature(std::shared_ptr<ast::FunctionSignature>);
    std::string mangleCanonicalName(std::string_view type, std::string_view method, ast::FunctionSignature::FunctionKind kind);
    
    std::string mangleTemplatedComplexType(TypeInfo *TI);
    
    bool isCanonicalInstanceMethodName(std::string_view ident);
}

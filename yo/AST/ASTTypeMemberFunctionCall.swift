//
//  ASTTypeMemberFunctionCall.swift
//  yo
//
//  Created by Lukas Kollmer on 27.05.18.
//  Copyright © 2018 Lukas Kollmer. All rights reserved.
//

import Foundation


// TODO is adding conformance to both ASTExpression and ASTStatement really the best idea here?
// What about introcuding a new node type `ASTExpressionStatement`?
struct ASTTypeMemberFunctionCall: ASTExpression & ASTStatement {
    let mangledName: String
    let target: ASTExpression
    let arguments: [ASTExpression]
    let unusedReturnValue: Bool
}

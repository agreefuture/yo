//
//  ASTFunctionCall.swift
//  yo
//
//  Created by Lukas Kollmer on 25.05.18.
//  Copyright © 2018 Lukas Kollmer. All rights reserved.
//

import Foundation


// TODO is adding conformance to both `ASTExpression` and `ASTStatement` really the best idea?
struct ASTFunctionCall: ASTExpression & ASTStatement {
    let functionName: String
    let arguments: [ASTExpression]
    let unusedReturnValue: Bool
}

//
//  ASTUnary.swift
//  yo
//
//  Created by Lukas Kollmer on 25.05.18.
//  Copyright © 2018 Lukas Kollmer. All rights reserved.
//

import Foundation


class ASTUnary: ASTExpression {
    enum Operator {
        case minus
    }
    
    let `operator`: ASTUnary.Operator = .minus // TOOD add support for other unary operators?
    let expression: ASTExpression
    
    init(expression: ASTExpression) {
        self.expression = expression
    }
}

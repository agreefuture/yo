//
//  ASTArraySetter.swift
//  yo
//
//  Created by Lukas Kollmer on 26.05.18.
//  Copyright © 2018 Lukas Kollmer. All rights reserved.
//

import Foundation


class ASTArraySetter: ASTStatement {
    let target: ASTExpression
    let offset: ASTExpression
    let value: ASTExpression
    
    init(target: ASTExpression, offset: ASTExpression, value: ASTExpression) {
        self.target = target
        self.offset = offset
        self.value  = value
    }
}

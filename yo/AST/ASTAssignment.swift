//
//  ASTAssignment.swift
//  yo
//
//  Created by Lukas Kollmer on 25.05.18.
//  Copyright © 2018 Lukas Kollmer. All rights reserved.
//

import Foundation


struct ASTAssignment: ASTStatement {
    let target: ASTExpression
    let value: ASTExpression
}

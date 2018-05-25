//
//  Lexer.swift
//  yo
//
//  Created by Lukas Kollmer on 24.05.18.
//  Copyright © 2018 Lukas Kollmer. All rights reserved.
//

import Foundation



// MARK: Constants

private let ignoredCharacters: [Unicode.Scalar] = [" ", "\n"]
private let set = CharacterSet(charactersIn: " .+-*/;(){}\n") // TODO give this a more descriptive name

private let tokenMapping: [String: TokenType] = [
    ";"     : .semicolon,
    "("     : .openingParentheses,
    ")"     : .closingParentheses,
    "{"     : .openingCurlyBrackets,
    "}"     : .closingCurlyBrackets,
    
    "+"     : .plus,
    "-"     : .minus,
    "*"     : .asterik,
    "/"     : .forwardSlash,
    "%"     : .percentageSign,
    
    // keywords
    "import": .import,
    "fn"    : .fn,
    "ret"   : .ret,
]


// MARK: Lexer

enum LexerError: Error {
    case unknownToken(String)
}

class Lexer {
    let source: String
    private var tokens = [Token]()
    
    init(source: String) {
        self.source = source
    }
    
    
    func tokenize() throws -> [Token] {
        var currentToken = ""
        
        
        let scalars = source.unicodeScalars.map { $0 }
        
        for (index, char) in scalars.enumerated() { // tbh i have no idea what i'm doing here
            if ignoredCharacters.contains(char) { continue }
            currentToken.unicodeScalars.append(char)
            
            let isLast = index == scalars.count - 1
            
            if !isLast {
                if set.contains(scalars[index + 1]) {
                    try handleRawToken(currentToken, endLocation: index)
                    currentToken = ""
                }
            } else {
                try handleRawToken(currentToken, endLocation: index)
            }
        }
        
        tokens.append(Token(type: .EOF, range: scalars.endIndex..<scalars.endIndex))
        
        return tokens
    }
    
    private func handleRawToken(_ rawToken: String, endLocation: Int) throws {
        
        let start = (endLocation + 1) - rawToken.count
        tokens.append(Token(type: try getType(token: rawToken), range: start..<endLocation))
    }
    
    
    private func getType(token: String) throws -> TokenType {
        
        if token.allScalarsInCharacterSet(.decimalDigits) { // TODO instead of the check, just call the Int/Double initializer w/ the string and return that if nonnull?
            return .numberLiteral(Int(token)!)
        }
        
        if let type = tokenMapping[token] {
            return type
        }
        
        if CharacterSet.letters.contains(token.unicodeScalars.first!) && token.allScalarsInCharacterSet(.alphanumerics) {
            return .identifier(token)
        }
        
        
        // should never reach here
        throw LexerError.unknownToken(token)
    }
}
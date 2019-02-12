//
//  Compiler.swift
//  yo
//
//  Created by Lukas Kollmer on 24.05.18.
//  Copyright © 2018 Lukas Kollmer. All rights reserved.
//

import Foundation


typealias GlobalFunctions = [String: FunctionSignature]



// MARK: Errors
enum BytecodeCompilerError: Error {
    // Function calls
    case undefinedFunction(ASTFunctionCall)
    case wrongNumberOfArgumentsPassedToFunction(ASTFunctionCall)
    
    
    case other(String, ASTNode)
}

// TODO
// - make this thread-safe?
// - add `increment()` and `decrement()` functions
// - rename `_counter` to `value` and make it public
struct Counter {
    private var _counter: Int
    private let fn: (Int) -> Int
    private let initial: Int
    
    init(initialValue: Int = 0, fn: @escaping (Int) -> Int = { $0 + 1 }) {
        self.initial = initialValue
        self._counter = initialValue
        self.fn = fn
    }
    
    mutating func get() -> Int {
        _counter = fn(_counter)
        return _counter
    }
    
    mutating func reset() {
        _counter = initial
    }
}


class ConstantArrayLiteralsCache {
    private var arrays = [[Int]: String]()
    
    
    func label(forArray array: [Int]) -> (label: String, wasAlreadyIncluded: Bool) {
        if let label = arrays[array] { return (label, true) }
        
        let label = UUID().uuidString
        arrays[array] = label
        
        return (label, false)
    }
}


struct ShortCircuitingJumpDestinations {
    /// Jump destination if the condition evaluated to `x != 0`
    let success: String?
    
    /// Jump destination if the condition evaluated to `x == 0`
    let failure: String?
}


private var ASTDeferStatement_associatedIdentifierHandle: UInt8 = 0
private extension ASTDeferStatement {
    var associatedIdentifier: ASTIdentifier! {
        get {
            return objc_getAssociatedObject(self, &ASTDeferStatement_associatedIdentifierHandle) as? ASTIdentifier
        }
        set {
            objc_setAssociatedObject(self, &ASTDeferStatement_associatedIdentifierHandle, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

private let ReservedIdentifiers: [ASTIdentifier] = ["nil"]


// MARK: Codegen

/// Class that compiles an AST to bytecode instructions
class BytecodeCompiler {
    
    private var instructions = [UnresolvedInstruction]()
    private var counter = Counter() // TODO use something that generates random 5 (or longer) letter strings instead? there's no actual benefit to having increasing counter values, using random strings would make clear thet the values have no intrinsic meaning
    private let constantArrayLiteralsCache = ConstantArrayLiteralsCache()
    
    
    // Scope info
    private var scope = Scope(type: .global)
    var typeCache = TypeCache()
    var functions = GlobalFunctions()
    var globals = [ASTVariableDeclaration]()
    var constants = [ASTConstantDeclaration]()
    
    private var codegen: AutoSynthesizedCodeGen!
    
    // Protocols that all types implicitly conform to
    // we have to keep them around as a list here, because lambda ASTs are generated at a later point
    // during the compilation process (when we encounter a lambda), which means that we call the other codegen thing
    // (the one generating initializers, dealloc functions, getters and setters) with only the lambda's ast, as opposed to
    // the beginning of the compilation process where we just shove the entire ast we got to the codegen thing
    private(set) var baseProtocols: [ASTProtocolDeclaration]!
    
    init() {
        // fill the functions table w/ all native functions
        Runtime.shared.builtins.forEach { functions[$0.name] = $0 }
    }
    
    
    func compile(ast _ast: AST) throws -> [UnresolvedInstruction] {
        var ast = _ast
        
        //var ast = try resolveImports(in: ast)
        
        baseProtocols = ast
            .compactMap { $0 as? ASTProtocolDeclaration }
            .filter { $0.annotations.contains(.base_protocol) }
    
        
        // perform semantic analysis
        let semanticAnalysis = SemanticAnalyzer().analyze(ast: ast)
        self.functions.insert(contentsOf: semanticAnalysis.globalFunctions)
        semanticAnalysis.types.forEach(self.typeCache.register)
        semanticAnalysis.enums.forEach(self.typeCache.register)
        self.constants.append(contentsOf: semanticAnalysis.constants)
        
        guard_allConstantsHaveAValidType(semanticAnalysis.constants)
        
        // TODO check that:
        // - there aren't type &/ enum decls using the same name
        // - there are no constants and static variables using the same name
        
        // Generate initializers, getters/setters and dealloc functions
        codegen = AutoSynthesizedCodeGen(compiler: self)
        codegen.fetchProtocols(fromAST: ast)
        codegen.synthesize(intoAST: &ast)
        
        // We have to append the globals found during semantic analysis later to make sure they come after the type metatables
        globals.append(contentsOf: semanticAnalysis.globals)
        
        globals.forEach { guard_identifierIsLegal($0.identifier) }
        
        // resolve enum parameters
        // TODO this is a shitty implementation
        // what about
        // - struct attributes
        // - local variables
        // - function return types
        functions.values
            .compactMap { $0 as? ASTFunctionSignature }
            .flatMap { $0.parameters }
            .forEach { $0.type = typeCache.resolveAsComplexOrEnum($0.type) }
        
        
        // Inserts the instructions to call a function w/ 0 arguments and a discarded return value
        let invoke_noChecks_noArgs_unusedRetval: (String) -> Void = { functionName in
            self.add(.push, unresolvedLabel: functionName)
            self.add(.call, 0)
            self.add(.pop)
        }
        
        
        // generate the bootstrapping instructions
        
        // call all static initializers
        invoke_noChecks_noArgs_unusedRetval("__INVOKING_ALL_STATIC_INITIALIZERS__")
        
        // call `main`
        try handle(node: ASTFunctionCall(functionName: "main", arguments: [], unusedReturnValue: false))
        
        // call cleanup functions
        invoke_noChecks_noArgs_unusedRetval("__INVOKING_ALL_STATIC_CLEANUP_FUNCTIONS__")
        
        // jump to `end`
        add(.ujump, unresolvedLabel: "end")
        let arrayLiteralsInsertionPoint = instructions.count
        
        // run codegen
        try ast.forEach(handle)
        
        // We have to delay handling globals until after all other codegen finished
        // because there might be additional types (and therefore additional mataypes) registered when handling lambdas
        try codegen.handleGlobals().forEach(handle)

        add(label: "end")
        
        return instructions
            .withArrayLiteralsResolved(insertionPoint: arrayLiteralsInsertionPoint)
            .withLabelsPadded()
    }
}


// MARK: Codegen
extension BytecodeCompiler {
    
    func add(_ operation: Operation, _ immediate: Int = 0) {
        instructions.append(.operation(operation, immediate))
    }
    
    func add(label: String) {
        instructions.append(.label(label))
    }
    
    func add(_ operation: Operation, unresolvedLabel: String) {
        instructions.append(.unresolved(operation, unresolvedLabel))
    }
    
    func add(_ instruction: UnresolvedInstruction) {
        instructions.append(instruction)
    }
    
    func add(comment: String) {
        instructions.append(.comment(comment))
    }
    
    
    // inserts all instructions generated in the block after the last label
    // useful when you're generating functions at compile time
    func handleFunctionInsertion<T>(_ block: () throws -> T) rethrows -> T {
        var previousInstructions = self.instructions
        self.instructions = []
        
        let retval = try block()
        
        // self.instructions now contains the instructions inserted in the block
        // we insert these
        guard let insertionPoint = previousInstructions.lastIndex(where: { $0.isLabel && !$0.labelValue!.hasPrefix(".") })?.advanced(by: 0) else {
            fatalError("unable to find insertion point")
            
        }
        
        previousInstructions.insert(contentsOf: self.instructions, at: insertionPoint)
        self.instructions = previousInstructions
        
        return retval
    }
    
    
    
    
    // updates the scope until `block` returns
    func withScope<T>(_ newScope: Scope, block: () throws -> T) rethrows -> T {
        let previousScope = scope
        scope = newScope
        
        defer {
            scope = previousScope
        }
        
        return try block()
    }
    
    
    func withUnsafeBlock<T>(block: () throws -> T) rethrows -> T {
        let oldValue = scope.isUnsafe
        scope.isUnsafe = true
        
        defer {
            scope.isUnsafe = oldValue
        }
        
        return try block()
    }
    
    
    var arcEnabledInCurrentScope: Bool {
        return !currentScopeHasAnnotation(.disable_arc)
    }
    
    func currentScopeHasAnnotation(_ annotation: ASTAnnotation.Element) -> Bool {
        guard let functionName = scope.functionName else {
            return false
        }
        
        return functions[functionName]!.hasAnnotation(annotation)
    }
    
    
    // TODO turn this into "offset of global in globals table" and drop the `16 +`
    func _actualAddressOfGlobal(withIdentifier identifier: ASTIdentifier) -> Int? {
        guard let index = globals.index(where: { $0.identifier == identifier }) else {
            return nil
        }
        return 16 + (index * 8)
    }
    
}

private extension BytecodeCompiler {
    
    func handle(node: ASTNode) throws {
        
        if let function = node as? ASTFunctionDeclaration {
            try handle(function: function)
            
        } else if let returnStatement = node as? ASTReturnStatement {
            try handle(return: returnStatement)
            
        } else if let numberLiteral = node as? ASTNumberLiteral {
            try handle(numberLiteral: numberLiteral)
            
        } else if let functionCall = node as? ASTFunctionCall {
            try handle(functionCall: functionCall)
            
        } else if let binop = node as? ASTBinaryOperation {
            try handle(binop: binop)
            
        } else if let identifier = node as? ASTIdentifier {
            try handle(identifier: identifier)
            
        } else if let unary = node as? ASTUnaryExpression {
            try handle(unary: unary)
            
        } else if let composite = node as? ASTComposite {
            try handle(composite: composite)
            
        } else if let assignment = node as? ASTAssignment {
            try handle(assignment: assignment)
            
        } else if let variableDeclaration = node as? ASTVariableDeclaration {
            guard_identifierIsLegal(variableDeclaration.identifier)
            if let initialValue = variableDeclaration.initialValue {
                try handle(assignment: ASTAssignment(target: variableDeclaration.identifier, value: initialValue))
            }
            
        } else if let comparison = node as? ASTComparison {
            try handle(comparison: comparison)
            
        } else if node is ASTStructDeclaration {
            // initializers etc have already been generated
            
        } else if let arraySetter = node as? ASTArraySetter {
            try handle(arraySetter: arraySetter)
            
        } else if let arrayGetter = node as? ASTArrayGetter {
            try handle(arrayGetter: arrayGetter)
            
        } else if let typeImplementation = node as? ASTTypeImplementation {
            try handle(typeImplementation: typeImplementation)
            
        } else if let typeMemberFunctionCall = node as? ASTTypeMemberFunctionCall {
            try handle(typeMemberFunctionCall: typeMemberFunctionCall)
            
        } else if let _ = node as? ASTImportStatement {
            
        } else if let stringLiteral = node as? ASTStringLiteral {
            try handle(stringLiteral: stringLiteral)
            
        } else if let rawInstruction = node as? ASTRawUnresolvedInstruction {
            add(rawInstruction.instruction)
            
        } else if let arrayLiteral = node as? ASTArrayLiteral {
            try handle(arrayLiteral: arrayLiteral)
            
        } else if let breakStatement = node as? ASTBreakStatement {
            try handle(breakStatement: breakStatement)
            
        } else if let continueStatement = node as? ASTContinueStatement {
            try handle(continueStatement: continueStatement)
            
        } else if let memberAccess = node as? ASTMemberAccess {
            try handle(memberAccess: memberAccess)
            
        } else if let typecast = node as? ASTTypecast {
            try handle(typecast: typecast)
            
        } else if let boxedExpression = node as? ASTBoxedExpression {
            try handle(boxedExpression: boxedExpression)
            
        } else if let _ = node as? ASTProtocolDeclaration {
            // pass? // TODO
            
        } else if let booleanLiteral = node as? ASTBooleanLiteral {
            try handle(booleanLiteral: booleanLiteral)
            
        } else if node is ASTEnumDeclaration {
            // already handled during semantic analysis
            
        } else if let _ = node as? ASTStaticMemberGetter {
            fatalError("do we ever reach here or can we safely delete this?")
            //try handle(staticMemberGetter: staticMemberGetter)
            
        } else if let _ = node as? ASTInlineBooleanExpression {
            fatalError("TODO reimplement")
            //try handle(condition: inlineBooleanExpression.condition)
            
        } else if let deferStatement = node as? ASTDeferStatement {
            try handle(composite: deferStatement.body)
            
        } else if let rangeLiteral = node as? ASTRangeLiteral {
            try handle(rangeLiteral: rangeLiteral)
            
        } else if let forLoop = node as? ASTForLoop {
            try handle(forLoop: forLoop)
            
        } else if let ifStatement = node as? ASTIfStatement {
            try handle(ifStatement: ifStatement)
        
        } else if let whileStatement = node as? ASTWhileStatement {
            try handle(whileStatement: whileStatement)
            
        } else if let condition = node as? ASTCondition {
            try handle(condition: condition)
            
        } else if let arbitraryNodes = node as? ASTArbitraryNodes {
            try arbitraryNodes.nodes.forEach(handle)
            //try handle(node: arbitraryNode)
            
        } else if let implicitNonZeroComparison = node as? ASTImplicitNonZeroComparison {
            try handle(implicitNonZeroComparison: implicitNonZeroComparison)
            
        } else if let pointerOperation = node as? ASTPointerOperation {
            try handle(pointerOperation: pointerOperation)
            
        } else if node is ASTConstantDeclaration {
            // pass
            
        } else if let _ = node as? ASTNoop {
            
        } else {
            fatalError("unhandled node \(node)")
        }
        
    }
    
    
    
    // MARK: Handle Statements
    
    func handle(function: ASTFunctionDeclaration) throws {
        guard function.body.getLocalVariables(recursive: true).intersection(with: function.signature.parameters).isEmpty else {
            // TODO this check is stupid. what if a local variable is declared w/ the same identifier, but a different type!
            fatalError("local variable cannot (yet?) shadow parameters")
        }
        
        if function.signature.isVariadic {
            guard [ASTType.ptr(.any), .Array].contains(function.signature.parameters.last!.type) else {
                fatalError("\(function.mangledName) declared as variadic, but the last parameter is neither `*any` nor `Array`")
            }
        }
        
        guard_noDuplicates(function.signature.parameters)
        
        let signature = function.signature
        
        // TODO wouldn't it make much more sense to create a new scope for each function?
        try withScope(Scope(type: .function(name: function.mangledName, returnType: signature.returnType), parameters: signature.parameters)) {
            // function entry point
            add(label: function.mangledName)
            
            if arcEnabledInCurrentScope {
                try signature.parameters
                    .filter { typeCache.supportsArc($0.type) }
                    .forEach { try retain(expression: $0.identifier) }
            }
            
            // Generate instructions for the function body
            // if the function doesn't have a return statement, we implicitly return 0
            let functionBody: ASTComposite
            
            if !(function.body.statements.last is ASTReturnStatement) {
                functionBody = ASTComposite(statements: function.body.statements + [ASTReturnStatement(expression: ASTNumberLiteral(0).as(.any))])
            } else {
                functionBody = function.body
            }
            
            functionBody.isUnsafe = function.signature.isUnsafe
            
            try handle(composite: functionBody)
        }
    }
    
    
    func handle(composite: ASTComposite) throws {
        guard case .function(let functionName, let returnType) = scope.type else {
            fatalError("top level composite outside a function?")
        }
        
        
        let isUnsafe_oldValue = scope.isUnsafe
        scope.isUnsafe = isUnsafe_oldValue || composite.isUnsafe
        defer {
            scope.isUnsafe = isUnsafe_oldValue
        }
        
        
        // if the composite _does_ introduce a new scope, we:
        // 1. allocate space on the stack for the new variables
        // 2. handle all statements
        // 3. insert `runtime::release` calls for all non-primitive variables declared in the composite
        let hasReturnStatement = composite.statements.any { $0 is ASTReturnStatement }
        var localVariables = composite.getLocalVariables(recursive: false)
        
        guard_noDuplicates(localVariables)
        
        // Automatic type inference 😎
        // Why is this an indexed for loop, instead of a map call?
        // We need to have access to the already processed variables.
        // Consider the following example
        // val x = 5;
        // val y = x;
        // When processing `y`, we need to be able to access the (already inferred) type of `x`
        
        for (index, variable) in localVariables.enumerated() {
            guard
                case .unresolved = variable.type,
                let initialValue = variable.initialValue
            else { continue }
            
            localVariables[index].type = try guessType(ofExpression: initialValue, additionalIdentifiers: localVariables)
        }
        
        
        
        // Handle defer blocks
        
        let DeferHandleType = ASTType.complex(name: "_DeferHandle")
        
        let deferHandles: [ASTVariableDeclaration] = composite.statements
            .compactMap { $0 as? ASTDeferStatement }
            .map { stmt in
                let identifier = ASTIdentifier("%defer_handle_\(counter.get())")
                stmt.associatedIdentifier = identifier
                return ASTVariableDeclaration(identifier: identifier, type: DeferHandleType)
            }
        
        localVariables.append(contentsOf: deferHandles)
        
        
        func handleDeferStatement(_ deferStatement: ASTDeferStatement) throws {
            let assignment = ASTAssignment(
                target: deferStatement.associatedIdentifier,
                value: ASTFunctionCall(
                    functionName: SymbolMangling.mangleInitializer(forType: "_DeferHandle"),
                    arguments: [
                        ASTLambda(
                            signature: .unresolved,
                            parameters: [],
                            body: deferStatement.body
                        )
                    ],
                    unusedReturnValue: false
                )
            )
            try handle(node: assignment)
        }
        
        
        
        
        // TODO maybe include a check to make sure that we managed to infer all types?
        //localVariables.forEach { print($0.type, $0.identifier.name) }
        
        // only used if `hasReturnStatement == true`
        let retval_temp_storage = ASTVariableDeclaration(
            identifier: ASTIdentifier(value: "__retval_\(functionName)"),
            type: returnType != .void ? returnType : .int
        )
        
        if arcEnabledInCurrentScope && hasReturnStatement {
            localVariables.append(retval_temp_storage)
        }
        
        
        try withScope(scope.adding(localVariables: localVariables)) {
            add(.alloc, localVariables.count)
            
            if !hasReturnStatement {
                for statement in composite.statements {
                    if let deferStatement = statement as? ASTDeferStatement {
                        try handleDeferStatement(deferStatement)
                    } else {
                        try handle(node: statement)
                    }
                }
                
                // Release defer handles
                try deferHandles.forEach { try release(expression: $0.identifier) }
                
                // This does not include any potential defer handles
                let localVariables = composite.getLocalVariables(recursive: false)
                
                try localVariables
                    .filter { typeCache.supportsArc($0.type) }
                    .forEach { try release(expression: $0.identifier) }
                
                add(.popi, localVariables.count + deferHandles.count)
            } else {
                // the composite contains a return statement
                // this means that we need to insert release calls for all objects in the local scope before handling the return statement
                // We also have to make sure that defer blocks are called before local variables are released
                
                for statement in composite.statements {
                    if let deferBlock = statement as? ASTDeferStatement {
                        try handleDeferStatement(deferBlock)
                        continue
                    }
                    
                    if arcEnabledInCurrentScope, let returnStatement = statement as? ASTReturnStatement {
                        
                        let returnedLocalIdentifier: ASTIdentifier?
                        
                        if let _returnedLocalIdentifier = returnStatement.expression as? ASTIdentifier,
                            scope.contains(identifier: _returnedLocalIdentifier.value),
                            case let type = try scope.type(of: _returnedLocalIdentifier.value),
                            typeCache.supportsArc(type)
                        {
                            returnedLocalIdentifier = _returnedLocalIdentifier
                        } else {
                            returnedLocalIdentifier = nil
                        }
                        
                        let storeRetval = ASTAssignment(
                            target: retval_temp_storage.identifier,
                            value: returnStatement.expression,
                            shouldRetainAssignedValueIfItIsAnObject: false
                        )
                        
                        try handle(assignment: storeRetval)
                        
                        // Release all defer handles
                        // We can't use rhe `deferHandles` array from above since this might very well be a nested scope
                        for deferHandle in scope.localVariables.filter({ $0.type == DeferHandleType }) {
                            if deferHandle != retval_temp_storage && (returnedLocalIdentifier == nil || deferHandle.identifier != returnedLocalIdentifier!) {
                                try release(expression: deferHandle.identifier)
                            }
                        }
                        
                        
                        if arcEnabledInCurrentScope {
                            try (scope.parameters + scope.localVariables)
                                .filter { $0 != retval_temp_storage }
                                .filter { $0.type != DeferHandleType }
                                .filter { returnedLocalIdentifier == nil || $0.identifier != returnedLocalIdentifier! }
                                .forEach { variable in
                                    let type = try scope.type(of: variable.identifier.value)
                                    if typeCache.supportsArc(type) {
                                        try release(expression: variable.identifier)
                                    }
                                }
                            
                            if let returnedLocalIdentifier = returnedLocalIdentifier {
                                try call(SymbolMangling.mangleStaticMember(ofType: "runtime", memberName: "markForRelease"), arguments: [returnedLocalIdentifier])
                            }
                        }
                        
                        try handle(return: ASTReturnStatement(expression: retval_temp_storage.identifier))
                        
                    } else {
                        try handle(node: statement)
                    }
                }
            }
            
        }
    }
    
    
    func handle(return returnStatement: ASTReturnStatement) throws {
        try handle(node: returnStatement.expression)
        add(.ret, scope.size)
    }
    
    
    // TODO guard that only primitive types can be subscripted (get & set)!
    
    // returns a tuple containing:
    // - elementSize: the size (in bytes) of one element in the target array (assuming that all elements have the same size!)
    // - offsetExpression: a binop multiplying the offset by the elementSize
    func _adjustSubscriptOffset(target: ASTExpression, offset: ASTExpression) throws -> (elementSize: Int, offsetExpression: ASTExpression) {
        let elementSize: Int
        
        let guessedTargetType = try guessType(ofExpression: target)
        
        switch guessedTargetType {
        case .any:
            return (sizeof(.any), offset)
            
        case .ptr(let type):
            elementSize = type.size
            
        default:
            elementSize = guessedTargetType.size
        }
        
        let offsetExpr = ASTBinaryOperation(
            lhs: ASTNumberLiteral(elementSize),
            operation: .mul,
            rhs: offset
        )
        
        return (elementSize, offsetExpr)
    }
    
    
    func loadh_operation(forSize size: ASTType.Size) -> Operation {
        switch size {
        case sizeof(.i8):  return .loadh_8
        case sizeof(.i16): return .loadh_16
        case sizeof(.i32): return .loadh_32
        case sizeof(.i64): return .loadh_64
        default: fatalError("unsupported size")
        }
    }
    
    
    func storeh_operation(forSize size: ASTType.Size) -> Operation {
        switch size {
        case sizeof(.i8):  return .storeh_8
        case sizeof(.i16): return .storeh_16
        case sizeof(.i32): return .storeh_32
        case sizeof(.i64): return .storeh_64
        default: fatalError("unsupported size")
        }
    }
    
    
    func handle(arrayGetter: ASTArrayGetter) throws {
        try guard_isSubscriptable(arrayGetter.target)
        
        let (elementSize, offset) = try _adjustSubscriptOffset(target: arrayGetter.target, offset: arrayGetter.offset)
        
        try handle(node: offset)
        try handle(node: arrayGetter.target)
        
        add(loadh_operation(forSize: arrayGetter.typeOfAccessedField?.size ?? elementSize))
    }
    
    
    func handle(arraySetter: ASTArraySetter) throws {
        try guard_isSubscriptable(arraySetter.target)
        
        let offset = try _adjustSubscriptOffset(target: arraySetter.target, offset: arraySetter.offset).offsetExpression
        
        try handle(node: arraySetter.value)
        try handle(node: offset)
        try handle(node: arraySetter.target)
        
        add(storeh_operation(forSize: try arraySetter.typeOfWrittenValue?.size ?? sizeof(guessType(ofExpression: arraySetter.value))))
    }

    
    func handle(typeImplementation: ASTTypeImplementation) throws {
        for function in typeImplementation.functions {
            try handle(function: function)
        }
    }
    
    func handle(typeMemberFunctionCall: ASTTypeMemberFunctionCall) throws {
        let call = ASTFunctionCall(
            functionName: typeMemberFunctionCall.mangledName,
            arguments: [typeMemberFunctionCall.target] + typeMemberFunctionCall.arguments,
            unusedReturnValue: typeMemberFunctionCall.unusedReturnValue
        )
        
        try handle(functionCall: call)
    }
    
    
    
    func handle(assignment: ASTAssignment) throws {
        let lhsType = try guessType(ofExpression: assignment.target)
        
        var rhs: ASTExpression = assignment.value
        
        if let lambda = rhs as? ASTLambda {
            rhs = try resolve(lambda: lambda, expectedSignature: lhsType)
        }
        
        let rhsType = try guessType(ofExpression: rhs)
        
        guard lhsType.isCompatible(with: rhsType) else {
            fatalError("cannot assign value of type `\(rhsType)` to `\(lhsType)`")
        }
        
        let shouldArcLhs = assignment.shouldRetainAssignedValueIfItIsAnObject && arcEnabledInCurrentScope && typeCache.supportsArc(lhsType)
        
        var target: ASTExpression = assignment.target
        
        if let targetIdentifier = target as? ASTIdentifier {
            
            if scope.contains(identifier: targetIdentifier.value) || _actualAddressOfGlobal(withIdentifier: targetIdentifier) != nil {
                
                let store: () throws -> Void
                
                if scope.contains(identifier: targetIdentifier.value) {
                    store = {
                        self.add(.store, try self.scope.index(of: targetIdentifier.value))
                    }
                } else if let globalAddress = _actualAddressOfGlobal(withIdentifier: targetIdentifier) {
                    store = {
                        self.add(.writeh, globalAddress)
                    }
                } else {
                    fatalError() // should never reach here
                }
                
                if !shouldArcLhs {
                    try handle(node: rhs)
                    try store()
                    return
                }
                
                // TODO what about lambdas? (they're encoded as ASTType.function)
                // TODO there's no need to release the olf value if this is the initial assignment
                try handle(node: rhs)
                try release(expression: targetIdentifier)
                try store()
                //add(.store, try scope.index(of: targetIdentifier.name))
                try retain(expression: targetIdentifier)
                return
            
            } else if let implicitSelfAccess = processPotentialImplicitSelfAccess(identifier: targetIdentifier) {
                target = implicitSelfAccess.memberAccess
                // fallthrough to the member access handling code below
            
            } else if let _ = _actualAddressOfGlobal(withIdentifier: targetIdentifier) {
                // TODO should we put code here?
                fatalError()
            }
        }
        
        
        if
            let memberAccess = target as? ASTMemberAccess,
            let (memberAccessGetterExpression, memberAccessTypes) = try processMemberAccess(memberAccess: memberAccess) as? (ASTArrayGetter, [ASTType])
        {
            // if we're assigning to some attribute, `memberAccessGetterExpression` is always an `ASTArrayGetter`
            
            
            let newAssignment = ASTArraySetter(
                target: memberAccessGetterExpression.target.as(.ptr(.i8)),
                offset: memberAccessGetterExpression.offset,
                value: rhs,
                typeOfWrittenValue: memberAccessTypes.last!
            )
            
            try handle(node: newAssignment)

        } else if let pointerOperation = target as? ASTPointerOperation {
            guard pointerOperation.operation == .deref else { fatalError() }
            
            let assignment = ASTArraySetter(
                target: pointerOperation.target,
                offset: ASTNumberLiteral(0),
                value: rhs
            )
            try handle(node: assignment) // TODO what about arc ?!??!!!!!
            return
            
        } else {
            fatalError("the fuck you doing?")
        }
        
    }
    
    
    
    
    
    
    // Conditional statement handling
    
    
    func handle(breakStatement: ASTBreakStatement) throws {
        fatalError() // TODO implement
    }
    
    func handle(continueStatement: ASTContinueStatement) throws {
        fatalError() // TODO implement
    }
    
    
    
    func handle(whileStatement: ASTWhileStatement) throws {
        // How does this work?
        // the code `while <cond> <body>` becomes the following asm:
        // cond:
        // <cond>
        
        // TODO what if the condition is an implicit nonzero check and the value we're checking is the refcounted result of a function call? in that case we'd need to insert a release statement
        
        let id = counter.get()
        let makeLabel: (String) -> String = { ".\(self.scope.functionName!)_while_\(id)_\($0)" }
        
        let label_cond = makeLabel("cond")
        //let label_body = makeLabel("body")
        let label_end  = makeLabel("end")
        
        // Handle the condition
        add(label: label_cond)
        try handle(condition: whileStatement.condition)
        add(.lnot) // Negate the result of the condition
        // If the top elent on the stack is 1 (ie, if the result of the condition was 0), we jump to `label_end`
        // Otherwise, fallthrough to the body
        add(.jump, unresolvedLabel: label_end)
        
        // Handle the body
        try handle(composite: whileStatement.body)
        add(.ujump, unresolvedLabel: label_cond)
        
        add(label: label_end)
    }
    
    
    
    func handle(forLoop: ASTForLoop) throws {
        let forLoopId = counter.get()
        
        let l_target   = ASTIdentifier(value: "%_target_\(forLoopId)")
        let l_iterator = ASTIdentifier(value: "%_iterator_\(forLoopId)")
        
        let identifier = forLoop.identifier
        let type = forLoop.type ?? .int
        
        let composite: ASTComposite = [
            ASTVariableDeclaration(identifier: l_target, type: .id),
            ASTVariableDeclaration(identifier: l_iterator, type: .id),
            
            ASTAssignment(target: l_target, value: forLoop.target),
            ASTAssignment(
                target: l_iterator,
                value: msgSend(target: l_target, selector: "iterator", arguments: [], unusedReturnValue: false)
            ),
            
            
            ASTWhileStatement(
                condition: ASTComparison(
                    lhs: msgSend(target: l_iterator, selector: "hasNext", arguments: [], unusedReturnValue: false).as(.bool),
                    operation: .equal,
                    rhs: ASTBooleanLiteral(true)
                ),
                body: [
                    ASTVariableDeclaration(
                        identifier: identifier,
                        type: type,
                        initialValue: msgSend(target: l_iterator, selector: "next", arguments: [], unusedReturnValue: false).as(type)
                    ),
                    forLoop.body // It's important this is included as a sub-composite. why? what if the body is unsafe?
                ]
            )
        ]
        
        try handle(composite: composite)
    }
    
    
    
    
    func handle(ifStatement: ASTIfStatement) throws {
        guard let functionName = scope.functionName else {
            ShouldNeverReachHere()
        }
        
        /*
         Q: How does this work?
         A: The generated instructions have the following structure:
         
         - initial if condition
         - goto `.initial_if_body` if true. otherwise fallthrough
         - for every `else if` condition:
           - `.else_if_COUNTER`
           - else if condition
           - goto `.else_if_COUNTER_body` if through, otherwise fallthrough
         
         - `.else_body`
         - (else body instructions)
         - goto `.if_end`
         
         - for every `else if`
           - `.else_if_COUNTER_body`
           - (else if instructions)
           - goto `.if_end`
         
         - `.initial_if_body`
         - `.if_end`
         */
        
        let id = counter.get()
        let makeLabel: (String) -> String = { ".\(functionName)_if_\(id)_\($0)" }
        let makeBranchEntryPointLabel: (Int) -> String = { makeLabel("branch_\($0)") }
        let makeConditionEntryPointLabel: (Int) -> String = { makeLabel("cond_\($0)") }
        
        let label_end = makeLabel("end")
        
        let hasElseBranch: Bool = {
            if case ._else(_) = ifStatement.branches.last! {
                return true
            }
            return false
        }()
        
        var branches = Array(ifStatement.branches.enumerated())
        
        // 1. handle all conditions
        for (index, branch) in branches {
            let hasNextConditionBranch = index < branches.count - (hasElseBranch ? 2 : 1)
            let label_currentBranchBody = makeBranchEntryPointLabel(index)
            let label_shortCircuitingFailure =
                hasNextConditionBranch
                    ? makeConditionEntryPointLabel(index + 1)
                    : (hasElseBranch
                        ? makeBranchEntryPointLabel(index + 1)
                        : label_end
                    )
            
            let shortCircuitingJumpOptions = ShortCircuitingJumpDestinations(success: label_currentBranchBody, failure: label_shortCircuitingFailure)
            
            switch branch {
            case ._if(let condition, _):
                try handle(condition: condition, shortCircuitingJumpOptions)
                add(.jump, unresolvedLabel: label_currentBranchBody)
                
            case ._else_if(let condition, _):
                add(label: makeConditionEntryPointLabel(index))
                try handle(condition: condition, shortCircuitingJumpOptions)
                add(.jump, unresolvedLabel: label_currentBranchBody)
            
            case ._else(_):
                // pass
                break
            }
        }
        
        
        // if the if statement doesn't have an else branch, there's nothing to fall through to
        if !hasElseBranch {
            add(.ujump, unresolvedLabel: label_end)
        } else {
            // if the if statement does have an else branch, we need to swap the first and last branch
            // bc we want the else branch first and the "main" branch last
            branches.swapAt(0, branches.count - 1)
        }
        
        // 2. handle all bodies
        for (index, branch) in branches {
            switch branch {
            case ._if(_, let body), ._else_if(_, let body), ._else(let body):
                add(label: makeBranchEntryPointLabel(index))
                try handle(composite: body)
            }
            
            add(.ujump, unresolvedLabel: label_end)
        }
        
        add(label: label_end)
        
    }
    
    
    
    
    
    
    
    // Lambdas
    
    
    
    func resolve(lambda: ASTLambda, expectedSignature type: ASTType) throws -> ASTExpression {
        
        // Resolve a lambda's parameter types
        // If the lambda already specifies an explicit type for a parameter, that one is used instead of the expected one
        let resolveLambdaParameterList: ([ASTVariableDeclaration], [ASTType]) -> [ASTVariableDeclaration] = { parameters, expectedTypes in
            return parameters.enumerated().map {
                if case .unresolved = $0.element.type {
                    return ASTVariableDeclaration(identifier: $0.element.identifier, type: expectedTypes[$0.offset])
                } else {
                    return $0.element
                }
            }
        }
        
        return try handleFunctionInsertion {
            guard case .unresolved = lambda.signature else {
                fatalError("lambda signature should still be unresolved at this point")
            }
            
            guard case .function(let returnType, let parameterTypes) = type else {
                fatalError("cannot assign a lambda to a non-function type value") // TODO better wording
            }
            
            guard let functionName = scope.functionName else {
                fatalError("using lambda outside a function")
            }
            
            // TODO make sure that a lambda can't be used w/in itself
            
            lambda.signature = type
            
            //let accessedIdentifiersFromOutsideScope = lambda.accessedIdentifiersFromOutsideScope
            let accessedIdentifiersFromOutsideScope =
                (scope.parameters + scope.localVariables)
                    .map { $0.identifier }
                    .intersection(with: lambda.accessedIdentifiersFromOutsideScope)
            noop()
            if accessedIdentifiersFromOutsideScope.isEmpty {
                // "pure" lambda
                let lambdaFunctionName = ASTIdentifier(value: "__\(functionName)_lambda_invoke_\(counter.get())")
                
                let fn = ASTFunctionDeclaration(
                    signature: ASTFunctionSignature(
                        name: lambdaFunctionName,
                        kind: .global,
                        parameters: resolveLambdaParameterList(lambda.parameters, parameterTypes),
                        returnType: returnType,
                        annotations: !arcEnabledInCurrentScope ? [.disable_arc] : [], // pure lambda literals inherit the `disable_arc` annotation from the function in which they were declared
                        isUnsafe: lambda.body.isUnsafe
                    ),
                    body: lambda.body
                )
                functions.insert(functionDeclaration: fn)
                
                try withScope(Scope(type: .global)) {
                    try handle(node: fn)
                }
                
                return lambdaFunctionName
                
            } else {
                // "impure" lambda
                
                let importedVariables: [ASTVariableDeclaration] = try accessedIdentifiersFromOutsideScope.map { .init(identifier: $0, type: try guessType(ofExpression: $0)) }
                
                let typename = "__\(functionName)_lambda_literal_\(counter.get())"
                let invoke_functionPtr = ASTIdentifier(value: SymbolMangling.mangleInstanceMember(ofType: typename, memberName: "invoke"))
                
                // the lambda type, as a function pointer that includes the lambda itself as first parameter
                let lambda_impType: ASTType     = .function(returnType: returnType, parameterTypes: [.complex(name: typename)] + parameterTypes)
                
                // the lambda type, how it would appear to the outside (ie w/out the lambda itself as first parameter)
                let lambda_impType_ext: ASTType = .function(returnType: returnType, parameterTypes: parameterTypes)
                
                
                // Lambda type
                
                let type = ASTStructDeclaration(
                    identifier: ASTIdentifier(value: typename),
                    attributes: [ASTVariableDeclaration(identifier: invoke_functionPtr, type: lambda_impType)] + importedVariables
                )
                typeCache.register(struct: type)
                
                var lambdaAST: AST = [type]
                self.codegen.synthesize(intoAST: &lambdaAST)
                
                try withScope(Scope(type: .global)) {
                    try lambdaAST.forEach(handle)
                }
                
                
                // Lambda implementation
                
                let imp = ASTFunctionDeclaration(
                    signature: ASTFunctionSignature(
                        name: "invoke",
                        kind: .impl(typename),
                        parameters: [.init(identifier: "__self", type: .complex(name: typename))] + resolveLambdaParameterList(lambda.parameters, parameterTypes),
                        returnType: returnType,
                        annotations: [],
                        isUnsafe: lambda.body.isUnsafe
                    ),
                    body: lambda.body
                )
                
                functions.insert(functionDeclaration: imp)
                
                try withScope(Scope(type: .global)) {
                    try handle(node: imp)
                }
                
                
                // NOTE:
                // The cast to `lambda_impType_ext` below is important because the function call returns `__FN_NAME_lambda_literal_x`.
                // Most likely, the lambda literal (aka the function call below) is being assigned to a local variable
                // or passed to some function. In either case, the other type is `fn<(...): ...>`, which would be incompatible w/ the return type of the lambda initializer
                
                return ASTFunctionCall(
                    functionName: SymbolMangling.mangleInitializer(forType: typename),
                    arguments: [invoke_functionPtr.as(.any)] + accessedIdentifiersFromOutsideScope,
                    unusedReturnValue: false
                ).as(lambda_impType_ext)
            }
        }
    }
    
    
    
    // MARK: Handle Expressions
    
    func handle(functionCall: ASTFunctionCall) throws {
        let identifier = ASTIdentifier(value: functionCall.functionName)
        let functionSignature: FunctionSignature
        
        var isGlobalFunction = !scope.contains(identifier: identifier.value)
        
        if !isGlobalFunction, case .function(let returnType, let parameterTypes) = try scope.type(of: identifier.value) {
            // calling a function from the local scope
            // TODO what about supporting implicit function calls on self (ie `foo()` instead of `self.foo()` if `self` has a function `foo`
            functionSignature = ASTFunctionSignature(parameterTypes: parameterTypes, returnType: returnType)
        
        } else if let globalFunctionSignature = functions[identifier.value] {
            // calling a global function
            functionSignature = globalFunctionSignature
            
        } else if let implicitSelfAccess = processPotentialImplicitSelfAccess(identifier: identifier), case .function(let returnType, let parameterTypes) = implicitSelfAccess.attributeType {
            isGlobalFunction = false
            functionSignature = ASTFunctionSignature(parameterTypes: parameterTypes, returnType: returnType)
        
        } else {
            fatalError("cannot resolve call to '\(identifier.value)'")
        }
        
        
        
        let isVariadic = functionSignature.isVariadic
        
        guard
            (!isVariadic && functionSignature.argc == functionCall.arguments.count)
            || (isVariadic && functionCall.arguments.count >= functionSignature.argc - 1) // -1 bc we don't count the last argument (the variadic one)
        else {
            fatalError("wrong argc in call to '\(identifier.value)': expected \(functionSignature.argc), got \(functionCall.arguments.count)")
        }
        
        
        // Special handling for functions resolved at compile time
        
        switch functionCall.functionName {
        case "runtime_Sdecltype":
            let type = try guessType(ofExpression: functionCall.arguments[0])
            try handle(node: ASTStringLiteral(value: type.typename))
            return
            
        case "runtime_Soffset":
            let typeName  = (functionCall.arguments[0] as! ASTIdentifier).value
            let fieldName = (functionCall.arguments[1] as! ASTIdentifier).value
            
            let offset = typeCache.offset(ofMember: fieldName, inType: typeName)
            try handle(numberLiteral: ASTNumberLiteral(offset))
            
            return
            
        default: break
        }
        
        
        let numberOfFixedArguments = !isVariadic
            ? functionCall.arguments.count
            : functionSignature.argc - 1
        
        
        // push fixed arguments on the stack
        for (index, var arg) in functionCall.arguments.prefix(upTo: numberOfFixedArguments).enumerated() {
            let expectedType = functionSignature.parameterTypes[index]
            
            if let lambda = arg as? ASTLambda {
                arg = try resolve(lambda: lambda, expectedSignature: expectedType)
            }
            
            // This is a terrible hack
            // Basically, the issue is that, if the implicit self argument is accessed via chained access (ie as an array getter)
            // `argType` is an int, instead of the actual expected type
            // We work around this by trying to detect implicit self arguments and casting them to the expected type
            // This should be solved by rewriting the parsing code to properly handle chained access
            if index == 0, functionCall.functionName.contains("_I"), arg is ASTArrayGetter {
                // TODO
                // a) is this still necessary?
                // b) under which circumstances do we end up here?
                arg = arg.as(expectedType)
            }
            
            if !functionSignature.hasAnnotation(.unchecked) {
                let argType = try guessType(ofExpression: arg)
                guard argType.isCompatible(with: expectedType) else {
                    fatalError("cannot pass '\(argType)' to function expecting '\(expectedType)'")
                }
            }
            
            try handle(node: arg)
        }
        
        // handle variadic arguments
        if isVariadic {
            // we can safely assume that `expectedType` is either `.ptr(.any)` or `Array`
            let expectedType = functionSignature.parameterTypes.last!
            let numberOfVariadicArguments = functionCall.arguments.count - numberOfFixedArguments
            
            if let spreadExpression = functionCall.arguments[safe: numberOfFixedArguments] as? ASTSpreadExpression {
                // Pass the spread expression directly, instead of turning it into an array
                let argType = try guessType(ofExpression: spreadExpression)
                guard argType.isCompatible(with: expectedType) else {
                    fatalError("Cannot pass spread expression of type '\(argType)' to variadic function expecting '\(expectedType)'")
                }
                try handle(node: spreadExpression.expression)
            
            } else {
                let arrayLiteral = ASTArrayLiteral(
                    elements: Array(functionCall.arguments.suffix(numberOfVariadicArguments)),
                    kind: expectedType == .ptr(.any) ? .primitive : .complex
                )
                try handle(node: arrayLiteral)
            }
        }
        
        //
        // Push the address onto the stack
        
        if let builtin = Runtime.shared[mangledName: identifier.value] {
            add(.push, builtin.address)
            
        } else if isGlobalFunction {
            let mangledName = SymbolMangling.mangleGlobalFunction(name: identifier.value)
            add(.push, unresolvedLabel: mangledName)
            
        } else if !isGlobalFunction {
            try handle(identifier: identifier)
        
        } else {
            fatalError("unable to resolve function call to \(functionCall.functionName)")
        }
        
        add(.call, !isVariadic ? numberOfFixedArguments : numberOfFixedArguments + 1)
        
        if functionCall.unusedReturnValue {
            if typeCache.supportsArc(functionSignature.returnType) {
                // return value is still on the stack
                try release(expression: ASTNoop())
            } else {
                add(.pop)
            }
        }
    }
    
    
    func handle(identifier: ASTIdentifier) throws {
        if identifier.isBuiltin {
            switch identifier.builtin_identifier {
            case .function:
                // #function expands to a string containing the name of the current function
                guard
                    case Scope.ScopeType.function(let mangledFunctionName, returnType: _) = scope.type,
                    let functionInfo = functions[mangledFunctionName]
                else {
                    fatalError("unable to expand #function")
                }
                
                var prettyFunctionName = mangledFunctionName
                prettyFunctionName += "("
                for (index, parameterType) in functionInfo.parameterTypes.enumerated() {
                    prettyFunctionName += parameterType.typename
                    if index < functionInfo.parameterTypes.count - 1 {
                        prettyFunctionName += ", "
                    }
                }
                prettyFunctionName += "): "
                prettyFunctionName += functionInfo.returnType.typename
                
                try handle(stringLiteral: ASTStringLiteral(value: prettyFunctionName))
                
            case .nil:
                try handle(numberLiteral: ASTNumberLiteral(0))
            }
            
            return
        }
        
        if let index = try? scope.index(of: identifier.value) {
            // local variable
            add(.load, index)
            
        } else if let selfAccess = processPotentialImplicitSelfAccess(identifier: identifier) {
            try handle(node: selfAccess.memberAccess)
            
        } else if functions.keys.contains(identifier.value) {
            // global function
            add(.push, unresolvedLabel: identifier.value)
            
        } else if let globalAddress = _actualAddressOfGlobal(withIdentifier: identifier) {
            add(.readh, globalAddress)
            
        } else if let constant = constants.first(where: { $0.identifier == identifier }) {
            try handle(node: constant.value)
    
        } else {
            fatalError("unable to resolve idenfifier '\(identifier)'")
        }
    }
    
    
    
    func processMemberAccess(memberAccess: ASTMemberAccess) throws -> (expr: ASTExpression, types: [ASTType]) {
        guard !memberAccess.members.isEmpty else {
            fatalError("wat")
        }
        
        if memberAccess.members.count == 1 {
            switch memberAccess.members[0] {
            case .initial_identifier(let identifier):
                return (identifier, [try guessType(ofExpression: identifier)])
            case .initial_functionCall(let functionCall):
                return (functionCall, [try guessType(ofExpression: functionCall)])
            default: fatalError("will never reach here")
            }
        }
        
        if
            memberAccess.members.count == 2,
            case .initial_identifier(let enumTypeName) = memberAccess.members[0],
            case .attribute(let caseName) = memberAccess.members[1],
            let caseIndex = typeCache.index(ofCase: caseName.value, inEnum: enumTypeName.value)
        {
            return (ASTNumberLiteral(caseIndex), [._enum(enumTypeName.value)])
        }
        
        var expr: ASTExpression!
        var types = [ASTType]()
        var currentType: ASTType {
            get { return types.last! }
            set { types.append(newValue) }
        }
        
        let updateType: (ASTIdentifier) throws -> Void = {
            guard case .complex(let currentTypename) = currentType else {
                fatalError("trying to access attribute on non-complex type")
            }
            currentType = self.typeCache.type(ofMember: $0.value, ofType: currentTypename)! // TODO don't force unwrap
        }
        
        
        for (index, member) in memberAccess.members.enumerated() {
            switch member {
            case .initial_identifier(let identifier):
                expr = identifier
                if !scope.contains(identifier: identifier.value), let selfAccess = processPotentialImplicitSelfAccess(identifier: identifier) {
                    currentType = selfAccess.selfType
                    expr = selfAccess.memberAccess
                    try updateType(identifier)
                    
                } else {
                    currentType = try self.scope.type(of: identifier.value)
                }
                
            case .initial_functionCall(let functionCall):
                expr = functionCall
                
                if scope.contains(identifier: functionCall.functionName) {
                    // TODO calling some local function / lambda?
                    fatalError() // TODO
                
                } else if let functionInfo = functions[functionCall.functionName] {
                    currentType = functionInfo.returnType
                
                } else {
                    fatalError("cannot resolve call to '\(functionCall.functionName)'")
                }
                
                
            case .attribute(let identifier):
                guard case .complex(let currentTypename) = currentType else {
                    fatalError("ugh")
                }
                
                expr = ASTArrayGetter(
                    target: expr.as(.ptr(.i8)),
                    offset: ASTNumberLiteral(typeCache.offset(ofMember: identifier.value, inType: currentTypename)),
                    typeOfAccessedField: typeCache.type(ofMember: identifier.value, ofType: currentTypename)!
                )
                
                if index < memberAccess.members.count {
                    try updateType(identifier)
                }
                
            case .functionCall(let functionName, let arguments, let unusedReturnValue):
                guard case .complex(let currentTypename) = currentType else { fatalError("ugh") } // TODO redundant code!!! (see above)
                
                if !typeCache.typeExists(withName: currentTypename) {
                    if currentTypename == "id" && scope.isUnsafe {
                        expr = msgSend(target: expr, selector: functionName.value, arguments: arguments, unusedReturnValue: unusedReturnValue)
                        currentType = .id
                        
                    } else {
                        fatalError("unable to resolve type of call target. wrap in an `unsafe` block to use dynamic dispatch instead")
                    }
                } else {
                    let mangledName = SymbolMangling.mangleInstanceMember(ofType: currentTypename, memberName: functionName.value)
                    
                    guard let functionInfo = functions[mangledName] else {
                        // TODO if `currentTypename` is `id` and we're in a `unsafe` block, turn this into an address lookup and call that instead
                        fatalError("unable to resolve member function call to '\(mangledName)'")
                    }
                    
                    expr = ASTTypeMemberFunctionCall(
                        mangledName: mangledName,
                        target: expr,
                        arguments: arguments,
                        unusedReturnValue: unusedReturnValue
                    )
                    
                    currentType = functionInfo.returnType
                }
            }
        }
        
        return (expr, types)
    }
    
    
    func handle(memberAccess: ASTMemberAccess) throws {
        try handle(node: processMemberAccess(memberAccess: memberAccess).expr)
    }
    
    
    func handle(typecast: ASTTypecast) throws {
        try handle(node: typecast.expression)
        
        let srcType = try guessType(ofExpression: typecast.expression)
        let dstType = typecast.type
        
        let intToDoubleConversion = srcType == .int && dstType == .double
        let doubleToIntConversion = srcType == .double && dstType == .int
        
        if intToDoubleConversion {
            add(.cvti2d)
        } else if doubleToIntConversion {
            add(.cvtd2i)
        }
    }
    
    
    func handle(binop: ASTBinaryOperation) throws {
        let lhsType = try guessType(ofExpression: binop.lhs)
        let rhsType = try guessType(ofExpression: binop.rhs)
        
        guard_allNumericBinaryOperationCompatibleTypes(
            types: [lhsType, rhsType],
            errorMessage: "Cannot perform binary operation \(binop.operation) with non-number types '\(lhsType)' and '\(rhsType)'"
        )
        
        // TODO switch to the commented-out version and disallow binops between different types
        
        // TODO add a check that only +-*/ can be used w/ doubles?
        
        /*guard lhsType == rhsType else {
            fatalError("Binary operation '\(binop.operation) cannot be applied to operands of type '\(lhsType.typename)' and '\(rhsType.typename)'")
        }
        
        try handle(node: binop.lhs)
        try handle(node: binop.rhs)
        
        switch lhsType {
        case .int:
            add(binop.operation.operation)
        
        case .double:
            add(binop.operation.operation.doubleVariant)
        
        default:
            fatalError("unhandled type \(lhsType.typename)")
        }*/
        
        
        let handleLhs = { try self.handle(node: binop.lhs) }
        let handleRhs = { try self.handle(node: binop.rhs) }
    
        let isInt: (ASTType) -> Bool = ASTType.intTypes.contains
        
        switch (lhsType, rhsType) {
        //case (.int, .int), (.any, .int), (.int, .any), (_, _) where true:
        case _ where (isInt(lhsType) && isInt(rhsType)) || (isInt(lhsType) && rhsType == .any) || (lhsType == .any && isInt(rhsType)) :
            try handleLhs()
            try handleRhs()
            add(binop.operation.operation)
            
        case (.double, .int):
            try handleLhs()
            try handleRhs()
            add(.cvti2d)
            add(binop.operation.operation.doubleVariant)
            
        case (.int, .double):
            try handleLhs()
            add(.cvti2d)
            try handleRhs()
            add(binop.operation.operation.doubleVariant)
            
        case (.double, .double):
            try handleLhs()
            try handleRhs()
            add(binop.operation.operation.doubleVariant)
            
        default:
            fatalError("unhandled binop w/ types \(lhsType) and \(rhsType)")
        }
    }
    
    
    func handle(unary: ASTUnaryExpression) throws {
        // TODO if `unary.expression` is a literal, perform at compile time?
        
        switch unary.operator {
        case .negate:
            try handle(binop: ASTBinaryOperation(lhs: ASTNumberLiteral(-1), operation: .mul, rhs: unary.expression))
        
        case .bitwiseNot:
            try handle(node: unary.expression)
            add(.not)
            
        case .logicalNegation:
            try handle(node: unary.expression)
            add(.lnot)
        }
    }
    
    
    func handle(numberLiteral: ASTNumberLiteral) throws {
        let value = numberLiteral.value
        
        if let _ = Int32(exactly: value) {
            add(.push, value)
        } else {
            // Doesn't fit in Int32 -> larger than 32 bits
            add(.push64)
            add(.raw(value))
        }
    }
    
    func handle(stringLiteral: ASTStringLiteral) throws {
        let text = stringLiteral.value
        let codepoints: [Int] = text.unicodeScalars.map { Int($0.value) } + [0]
        //let codepoints: [Int] = text.unicodeScalars.reduce(into: [text.unicodeScalars.count]) { $0.append(Int($1.value)) }
        
        //let (label, alreadyRegistered) = stringLiteralsCache.label(forStringLiteral: text)
        let (label, alreadyRegistered) = constantArrayLiteralsCache.label(forArray: codepoints)
        if !alreadyRegistered {
            add(.arrayLiteral(label, sizeof(.i8), codepoints))
        }
        
        let stringInitCall = ASTFunctionCall(
            functionName: SymbolMangling.mangleInitializer(forType: "String"),
            arguments: [
                ASTRawUnresolvedInstruction(instruction: .unresolved(.loadc, label))
            ],
            unusedReturnValue: false
        )
        
        try handle(functionCall: stringInitCall)
    }
    
    
    func handle(arrayLiteral: ASTArrayLiteral) throws {
        // TODO if the array is just number literals, store it as a constant (like strings)
        // otherwise, just generate a bunch of Array.add calls? (that wouldn't work inline)
        
        if arrayLiteral.elements.isEmpty {
            guard arrayLiteral.kind != .primitive else {
                fatalError("can't allocate an empty primitive array")
            }
            
            let newCall = ASTFunctionCall(
                functionName: SymbolMangling.mangleStaticMember(ofType: "Array", memberName: "new"),
                arguments: [],
                unusedReturnValue: false
            )
            try handle(node: newCall)
            return
        }
        
        let isConstant = arrayLiteral.elements.all { $0 is ASTNumberLiteral }
        
        if isConstant {
            guard arrayLiteral.kind == .primitive else {
                fatalError("constant non-primitive (aka complex) array literals aren't a thing")
            }
            
            let values = arrayLiteral.elements.map { ($0 as! ASTNumberLiteral).value }
            
            let (label, isAlreadyRegistered) = constantArrayLiteralsCache.label(forArray: values)
            if !isAlreadyRegistered {
                add(.arrayLiteral(label, sizeof(.i64), values)) // TODO allow custom element size?
            }
            
            // Problem: the array we got from the `loadc` instruction above (or, to be precise, the pointer to the array)
            // has its length as its first element.
            // We don't care about that, which is why we need to copy all elements following the first to a new array and free the old one.
            
            // Because we can't really implement this here (the address is already on the stack!), we use a helper function
            /*let call = ASTFunctionCall(
                functionName: SymbolMangling.mangleStaticMember(ofType: "runtime", memberName: "_primitiveArrayFromConstant"),
                arguments: [
                    ASTRawUnresolvedInstruction(instruction: .unresolved(.loadc, label))
                ],
                unusedReturnValue: false
            )
            try handle(functionCall: call)*/
            
            add(.unresolved(.loadc, label))
            
            return
        }
        
        // The code below is awful (not the code but the concept)
        // TODO come up w/ a better solution (variadic functions?)
        // TODO if we create a new array initializer for each #elements, we have a ton of duplicate code. maybe we can avoid that somehow?
        
        let elements = arrayLiteral.elements
        
        if arrayLiteral.kind == .primitive {
            //guard try elements.all({ try guessType(ofExpression: $0).isCompatible(with: .int) }) else {
            //    fatalError("primitive array literal contains complex elements")
            //}
            
            let initializerName = "_specializedPrimitiveArrayInitializerName\(elements.count)"
            let mangledInitializerName = SymbolMangling.mangleStaticMember(ofType: "runtime", memberName: initializerName)
            
            if !functions.keys.contains(mangledInitializerName) {
                let array: ASTIdentifier = "array"
                
                let specializedInitializer = ASTFunctionDeclaration(
                    signature: ASTFunctionSignature(
                        name: ASTIdentifier(initializerName),
                        kind: .staticImpl("runtime"),
                        parameters: (0..<elements.count).map { ASTVariableDeclaration(identifier: ASTIdentifier("_\($0)"), type: .any) },
                        returnType: .ptr(.i64)
                    ),
                    body: [
                        ASTVariableDeclaration(identifier: array, type: .ptr(.any)), // TODO i64
                        ASTAssignment(
                            target: array,
                            value: ASTFunctionCall(
                                functionName: SymbolMangling.alloc,
                                arguments: [ASTNumberLiteral(elements.count * sizeof(.i64))], // TODO allow explicitly typed primitive array literals?
                                unusedReturnValue: false
                            )
                        ),
                        
                        ASTComposite(statements: (0..<elements.count).map { index in
                            ASTArraySetter(
                                target: array,
                                offset: ASTNumberLiteral(index),
                                value: ASTIdentifier(value: "_\(index)")
                            )
                        }),
                        
                        ASTReturnStatement(expression: array)
                    ]
                )
                
                
                try handleFunctionInsertion {
                    functions.insert(functionDeclaration: specializedInitializer)
                    try withScope(Scope(type: .global)) {
                        try handle(function: specializedInitializer)
                    }
                }
            }
            
            let initializerCall = ASTFunctionCall(functionName: mangledInitializerName, arguments: elements, unusedReturnValue: false)
            try handle(node: initializerCall)
            return
        }
        
        
        // Complex array literal
        
        guard try elements.all({ try guessType(ofExpression: $0).isComplex }) else {
            fatalError("A complex array literal cannot contain non-complex elements")
        }
        
        let arrayInitializerMemberName = "_arrayLiteralInit\(arrayLiteral.elements.count)"
        let arrayInitializerMangled = SymbolMangling.mangleStaticMember(ofType: "Array", memberName: arrayInitializerMemberName)
        
        if !functions.keys.contains(arrayInitializerMangled) {
            let array = ASTIdentifier(value: "array")
            
            let specializedArrayInitializer = ASTFunctionDeclaration(
                signature: ASTFunctionSignature(
                    name: ASTIdentifier(arrayInitializerMemberName),
                    kind: .staticImpl("Array"),
                    parameters: (0..<elements.count).map { ASTVariableDeclaration(identifier: ASTIdentifier("_\($0)"), type: .id) },
                    returnType: .Array
                ),
                body: [
                    // create the array
                    ASTVariableDeclaration(identifier: array, type: .Array),
                    ASTAssignment(
                        target: array,
                        value: ASTFunctionCall(
                            functionName: SymbolMangling.mangleStaticMember(ofType: "Array", memberName: "new"),
                            arguments: [],
                            unusedReturnValue: false
                        )
                    ),
                    
                    // fill the array
                    // TODO we could optimize this by providing an Array initializer that takes an initial capacity, then simply set via offset assignment (that'd avoid the length checks and resizing)
                    ASTComposite(statements: (0..<elements.count).map { idx in
                        ASTTypeMemberFunctionCall(
                            mangledName: SymbolMangling.mangleInstanceMember(ofType: "Array", memberName: "append"),
                            target: array,
                            arguments: [ASTIdentifier(value: "_\(idx)")],
                            unusedReturnValue: true
                        )
                    }),
                    
                    
                    // return
                    ASTReturnStatement(expression: array)
                ]
            )
            
            try handleFunctionInsertion {
                functions.insert(functionDeclaration: specializedArrayInitializer)
                try withScope(Scope(type: .global)) {
                    try handle(node: specializedArrayInitializer)
                }
            }
        }
        
        let initializerCall = ASTFunctionCall(functionName: arrayInitializerMangled, arguments: elements, unusedReturnValue: false)
        try handle(node: initializerCall)
    }
    
    
    func handle(boxedExpression: ASTBoxedExpression) throws {
        let type = try guessType(ofExpression: boxedExpression.expression)
        
        guard type.isTriviallyRepresentableAsInteger || type == .double else {
            fatalError("Unable to box expression of type \(type)")
        }
        
        let _type: Int
        
        switch type {
        case .bool:
            _type = Constants.NumberTypeMapping.boolean
        case .double:
            _type = Constants.NumberTypeMapping.double
        default:
            _type = Constants.NumberTypeMapping.integer
        }
        
        let initCall = ASTFunctionCall(
            functionName: SymbolMangling.mangleInitializer(forType: "Number"),
            arguments: [boxedExpression.expression, ASTNumberLiteral(_type).as(.any)],
            unusedReturnValue: false
        )
        
        try handle(node: initCall)
    }
    
    
    func handle(booleanLiteral: ASTBooleanLiteral) throws {
        add(.push, booleanLiteral.value ? 1 : 0)
    }
    
    
    func handle(rangeLiteral: ASTRangeLiteral) throws {
        let factoryMethodName = String(describing: rangeLiteral.kind) // returns the name of the enum case (`inclusive` or `exclusive`)
        let initCall = ASTFunctionCall(
            functionName: SymbolMangling.mangleStaticMember(ofType: "Range", memberName: factoryMethodName),
            arguments: [rangeLiteral.start, rangeLiteral.end],
            unusedReturnValue: false
        )
        
        try handle(node: initCall)
    }
    
    
    
    func handle(condition: ASTCondition, _ shortCircuitingJumpDestinations: ShortCircuitingJumpDestinations? = nil) throws {
        if let comparison = condition as? ASTComparison {
            try handle(comparison: comparison)
            
        } else if let binaryCondition = condition as? ASTBinaryCondition {
            try handle(binaryCondition: binaryCondition, shortCircuitingJumpDestinations)
            
        } else if let implicitNonZeroComparison = condition as? ASTImplicitNonZeroComparison {
            try handle(implicitNonZeroComparison: implicitNonZeroComparison)
            
        } else {
            fatalError("unhandled condition \(condition)")
        }
    }
    
    
    func handle(comparison: ASTComparison) throws {
        let lhsType = try guessType(ofExpression: comparison.lhs)
        let rhsType = try guessType(ofExpression: comparison.rhs)
        
        // TODO enable type checks for comparisons
        
        //guard_allNumericBinaryOperationCompatibleTypes(
        //    types: [lhsType, rhsType],
        //    errorMessage: "Cannot perform binary comparison \(comparison.operation) with non-number types '\(lhsType)' and '\(rhsType)'"
        //)
        
        //guard lhsType.isCompatible(with: rhsType) else {
        //    fatalError("Cannot perform binary comparison with incompaible types '\(lhsType)' and '\(rhsType)'")
        //}
        
        try handle(node: comparison.lhs)
        try handle(node: comparison.rhs)
        
        let shouldUseDoubleVariant = [lhsType, rhsType].all { $0 == .double }
        
        switch comparison.operation {
        case .equal:
            add(shouldUseDoubleVariant ? .d_eq : .eq)
        case .notEqual:
            add(shouldUseDoubleVariant ? .d_eq : .eq)
            add(.lnot)
        case .less:
            add(shouldUseDoubleVariant ? .d_lt : .lt)
        case .greater:
            add(shouldUseDoubleVariant ? .d_le : .le)
            add(.lnot)
        case .lessEqual:
            add(shouldUseDoubleVariant ? .d_le : .le)
        case .greaterEqual:
            add(shouldUseDoubleVariant ? .d_lt : .lt)
            add(.lnot)
        }
    }
    
    
    func handle(binaryCondition: ASTBinaryCondition, _ shortCircuitingJumpDestinations: ShortCircuitingJumpDestinations?) throws {
        if let destinations = shortCircuitingJumpDestinations {
            switch binaryCondition.operator {
            case .and: // both need to be true
                try handle(condition: binaryCondition.lhs, destinations)
                if let dest_failure = destinations.failure {
                    add(.lnot)
                    add(.jump, unresolvedLabel: dest_failure)
                }
                try handle(condition: binaryCondition.rhs, destinations)
                
            case .or: // at least one needs to be true
                try handle(condition: binaryCondition.lhs, destinations)
                if let dest_success = destinations.success {
                    add(.jump, unresolvedLabel: dest_success)
                }
                try handle(condition: binaryCondition.rhs, destinations)
            }
        } else {
            // No short circuiting
            
            try handle(node: binaryCondition.lhs)
            try handle(node: binaryCondition.rhs)
            
            // the last two values on the stack are now one of these options:
            // 1, 1   (lhs: true  | rhs: true )
            // 1, 0   (lhs: true  | rhs: false)
            // 0, 1   (lhs: false | rhs: true )
            // 0, 0   (lhs: false | rhs: false)
            
            // we now add the last two entries on the stack
            // if the result is 2, both are true
            // if the result is 1, one of them is true
            // if the result is 0, both are false
            
            add(.add)
            
            // depending on the comparison operator (&& or ||) we now compare the sum
            // with the expected result
            
            switch binaryCondition.operator {
            case .and:
                // both need to be true
                add(.push, 2)
                add(.eq)
                
            case .or:
                // at least one needs to be true
                // make sure the sum is greater than ot equal to 1
                add(.push, 1)
                add(.lt)
                add(.lnot)
            }
        }
    }
    
    
    func handle(implicitNonZeroComparison: ASTImplicitNonZeroComparison) throws {
        let comparison = ASTComparison(
            lhs: implicitNonZeroComparison.expression,
            operation: .notEqual,
            rhs: ASTNumberLiteral(0)
        )
        
        try handle(comparison: comparison)
    }
    
    
    func handle(pointerOperation: ASTPointerOperation) throws {
        let op = pointerOperation.operation
        let target = pointerOperation.target
        
        // TODO this shortcut is probably wrong?
        if op == .ref_absolute, case .ptr(_) = try guessType(ofExpression: target) {
            try handle(node: target)
            add(.addr_cvt2abs)
            return
        }
        
        switch op {
        case .ref, .ref_absolute: // Push the address of `target` onto the stack
            if let identifier = target as? ASTIdentifier {
                if let frameIndex = try? scope.index(of: identifier.value) {
                    add(.push_fp)
                    add(.push, frameIndex * sizeof(.int)) // TODO update when adding variable stack element sizes
                    add(.sub)
                } else {
                    fatalError("TODO")
                }
            } else if let memberAccess = target as? ASTMemberAccess {
                guard case .attribute(name: let identifier) = memberAccess.members.last! else { fatalError() }
                let (expr, types) = try processMemberAccess(memberAccess: ASTMemberAccess(members: Array(memberAccess.members.dropLast())))
                let type = types[0]
                
                try handle(node: expr)
                add(.push, typeCache.offset(ofMember: identifier.value, inType: type.typename))
                add(.add)
            } else {
                fatalError("Unhandled ref target: \(target)")
            }
            
            if pointerOperation.operation == .ref_absolute {
                // TODO add an operation to convert the address (currently relative to the beginning of our heap) to something absolute
                add(.addr_cvt2abs)
            }
            
        case .deref:
            // TODO this is implemenyed twice (also in assignment target handling)
            if  let identifier = target as? ASTIdentifier,
                let targetType = try? scope.type(of: identifier.value),
                case .ptr(let underlyingType) = targetType
            {
                try handle(node: identifier) // pushes the address of the pointer on the stack
                add(.push, 0)
                add(loadh_operation(forSize: underlyingType.size))
            } else {
                fatalError("Unhandled deref target: \(target)")
            }
        }
    }
}


private extension BytecodeCompiler {
    func guard_allNumericBinaryOperationCompatibleTypes(types: [ASTType], errorMessage: String) {
        guard types.all(([ASTType.double, .any] + ASTType.intTypes).contains) else {
            fatalError(errorMessage)
        }
    }
    
    func guard_noDuplicates(_ declarations: [ASTVariableDeclaration]) {
        var identifiers = [ASTIdentifier]()
        
        for identifier in declarations.map({ $0.identifier }) {
            guard !identifiers.contains(identifier) else {
                fatalError("Invalid redeclaration of `\(identifier)`")
            }
            identifiers.append(identifier)
        }
    }
    
    func guard_identifierIsLegal(_ identifier: ASTIdentifier) {
        if ReservedIdentifiers.contains(identifier) {
            fatalError("Identifier '\(identifier.value)' is reserved")
        }
    }
    
    func guard_allConstantsHaveAValidType(_ constants: [ASTConstantDeclaration]) {
        for constant in constants where !constant.annotations.contains(.unchecked) {
            guard try! constant.type.isTriviallyRepresentableAsInteger && self.guessType(ofExpression: constant.value).isTriviallyRepresentableAsInteger else {
                fatalError("Constant '\(constant.identifier.value)' has unsupported type '\(constant.type)'")
            }
        }
    }
    
    func guard_isSubscriptable(_ expr: ASTExpression) throws {
        let type = try guessType(ofExpression: expr)
        
        switch type {
        case .Array, .ptr(_): return
        default:
            fatalError("Type '\(type.typename)' cannot be subscripted")
        }
    }
}


private extension BytecodeCompiler {
    func processPotentialImplicitSelfAccess(identifier: ASTIdentifier) -> (memberAccess: ASTMemberAccess, selfType: ASTType, attributeType: ASTType)? {
        guard let selfName = scope.parameters.first?.identifier.value else {
            return nil
        }
        
        if scope.contains(identifier: selfName), case .complex(let self_type) = try! scope.type(of: selfName), typeCache.type(self_type, hasMember: identifier.value) {
            return (
                ASTMemberAccess(members: [
                    .initial_identifier(.init(selfName)),
                    .attribute(name: identifier)
                ]),
                ASTType.complex(name: self_type),
                typeCache.type(ofMember: identifier.value, ofType: self_type)!
            )
        }
        return nil
    }
}


private extension BytecodeCompiler {
    func guessType(ofExpression expression: ASTExpression, additionalIdentifiers: [ASTVariableDeclaration] = []) throws -> ASTType {
        return try withScope(scope.adding(localVariables: additionalIdentifiers)) {
            if let identifier = expression as? ASTIdentifier {
                
                if identifier.isBuiltin {
                    return identifier.builtin_type
                }
                
                if scope.contains(identifier: identifier.value) {
                    return try scope.type(of: identifier.value)
                    
                } else if let functionInfo = functions[identifier.value] {
                    return ASTType.function(returnType: functionInfo.returnType, parameterTypes: functionInfo.parameterTypes)
                    
                } else if let implicitSelfAccess = processPotentialImplicitSelfAccess(identifier: identifier) {
                    return implicitSelfAccess.attributeType
                
                } else if let global = globals.first(where: { $0.identifier == identifier }) {
                    return global.type
                } else if let constant = constants.first(where: { $0.identifier == identifier }) {
                    return constant.type
                }
                
            } else if let functionCall = expression as? ASTFunctionCall {
                if let returnType = functions[functionCall.functionName]?.returnType {
                    return returnType
                } else {
                    // not a global function, maybe something from the current scope
                    if scope.contains(identifier: functionCall.functionName), case .function(let returnType, _) = try scope.type(of: functionCall.functionName) {
                        return returnType
                    
                    } else if case .function(let returnType, _)? = processPotentialImplicitSelfAccess(identifier: ASTIdentifier(value: functionCall.functionName))?.attributeType {
                        return returnType
                    
                    } else {
                        fatalError("[\(#function)] unable to resolve function call to `\(functionCall.functionName)`")
                    }
                }
                
            } else if let typecast = expression as? ASTTypecast {
                return typecast.type
                
            } else if let numberLiteral = expression as? ASTNumberLiteral {
                return numberLiteral.type
                
            } else if let binop = expression as? ASTBinaryOperation {
                let lhsType = try guessType(ofExpression: binop.lhs)
                let rhsType = try guessType(ofExpression: binop.rhs)
                
                // TODO document this?!!!
                if [lhsType, rhsType].contains(.double) {
                    return .double
                }
                return .int
                
            } else if let unaryExpression = expression as? ASTUnaryExpression {
                return try guessType(ofExpression: unaryExpression.expression)
                
            } else if expression is ASTStringLiteral {
                return .String
                
            } else if expression is ASTNoop {
                return .any // TODO is this the right choice? // UPDATE does it even matter? do we ever reach here?
                
            } else if let arrayLiteral = expression as? ASTArrayLiteral {
                return arrayLiteral.kind == .complex ? .Array : .ptr(.i64)
                
            } else if expression is ASTBooleanLiteral {
                return .bool
                
            } else if let assignedValueMemberAccess = expression as? ASTMemberAccess {
                return try processMemberAccess(memberAccess: assignedValueMemberAccess).types.last!
                
            } else if let arrayGetter = expression as? ASTArrayGetter {
                if let type = arrayGetter.typeOfAccessedField {
                    return type
                }
                
                let targetType = try guessType(ofExpression: arrayGetter.target)
                if case .ptr(let type) = targetType {
                    return type
                } else {
                    return targetType
                }
                
            } else if let typeMemberFunctionCall = expression as? ASTTypeMemberFunctionCall {
                return functions[typeMemberFunctionCall.mangledName]!.returnType // TODO don't force unwrap!
            
            } else if let boxedExpression = expression as? ASTBoxedExpression {
                return try boxedType(ofExpression: boxedExpression.expression)
            
            } else if expression is ASTRawUnresolvedInstruction {
                return .any
                
            } else if expression is ASTInlineBooleanExpression {
                return .bool
                
            } else if expression is ASTRangeLiteral {
                return .complex(name: "Range")
            
            } else if let staticMemberGetter = expression as? ASTStaticMemberGetter {
                if typeCache.enumExists(withName: staticMemberGetter.typename.value) {
                    return .int // enums are ints
                    // TODO what about introducing an `ASTType.enum` case?
                }
                fatalError("static member getter for unregistered type?!")
                // TOOD what about using static member getters to refer to functions in an impl?
            } else if let arbitraryNodes = expression as? ASTArbitraryNodes {
                switch arbitraryNodes.typeInferenceHelper {
                case .expression(let expr):
                    return try guessType(ofExpression: expr)
                case .type(let type):
                    return type
                }
            } else if let pointerOperation = expression as? ASTPointerOperation {
                let targetType = try guessType(ofExpression: pointerOperation.target)
                switch pointerOperation.operation {
                case .ref, .ref_absolute:
                    return .ptr(targetType)
                case .deref:
                    guard case .ptr(let underlyingType) = targetType else {
                        fatalError("Cannot get underlying type for non-pointer type '\(targetType)'")
                    }
                    return underlyingType
                }
            } else if let spreadExpression = expression as? ASTSpreadExpression {
                return try guessType(ofExpression: spreadExpression.expression)
            }
            
            // We seem to hit this error pretty often (/always?) when encountering an undefined identifier
            // TODO add a check whether the identifier actually exists first, so that we can throw a proper error message
            fatalError("unable to infer type of \(expression)")
        }
    }
    
    
    func boxedType(ofExpression expression: ASTExpression) throws -> ASTType {
        let type = try guessType(ofExpression: expression)
        switch type {
        case .bool, .double, ._enum(_), // TODO use .isTriviallyRepresentableAsAnInteger or whatever its called
        _ where ASTType.intTypes.contains(type):
            return .complex(name: "Number")
        default:
            return .unresolved
        }
    }
}


extension BytecodeCompiler {
    func msgSend(target: ASTExpression, selector: String, arguments: [ASTExpression], unusedReturnValue: Bool) -> ASTExpression {
        return ASTFunctionCall(
            functionName: SymbolMangling.mangleStaticMember(ofType: "runtime", memberName: "msgSend"),
            arguments: [
                target,   // The target of the method call
                ASTStringLiteral(value: selector),  // selector
                ASTNumberLiteral(arguments.count)   // argc
                ]
                + arguments                 // the actual arguments
                + [ASTNumberLiteral(0)],   // 0 (unused, see below)
            // Q: why do we append the unused 0?
            // A: `runtime::msgSend` is variadic, with a primitive array, meaning that there has to be at least one non-fixed argument\
            //    However, we have to handle the case where this is a method call that doesn't take any parameters
            unusedReturnValue: unusedReturnValue
        ).as(.id) // TODO is .id the right choice? does that work w/ the existing arc implementation?
    }
}



extension BytecodeCompiler {
    func retain(expression: ASTExpression) throws {
        add(comment: "retain \((expression as? ASTIdentifier)?.value ?? String(describing: expression)) (\(try guessType(ofExpression: expression)))")
        try handle(node: expression)
        add(.retain, kARCOperationPopAddressOffStack)
    }
    
    func release(expression: ASTExpression) throws {
        add(comment: "release \((expression as? ASTIdentifier)?.value ?? String(describing: expression)) (\(try guessType(ofExpression: expression)))")
        try handle(node: expression)
        add(.release, kARCOperationPopAddressOffStack)
    }
    
    func call(_ functionName: String, arguments: [ASTExpression], unusedReturnValue: Bool = true) throws {
        add(comment: "\(functionName) \((arguments.first as? ASTIdentifier)?.value ?? String(describing: arguments.first)) (\(try guessType(ofExpression: arguments.first!)))")
        let call = ASTFunctionCall(
            functionName: functionName,
            arguments: arguments,
            unusedReturnValue: unusedReturnValue
        )
        try handle(functionCall: call)
    }
}

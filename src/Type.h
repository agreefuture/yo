//
//  Type.h
//  yo
//
//  Created by Lukas Kollmer on 2019-08-18.
//  Copyright © 2019 Lukas Kollmer. All rights reserved.
//

#pragma once

#include "util.h"
#include <vector>
#include <utility>


namespace llvm {
    class Type;
    class DIType;
}


NS_START(yo::irgen)


enum class CallingConvention {
    C
};


class Type;
class NumericalType;
class StructType;
class PointerType;
class FunctionType;
class StructType;



class Type {
public:
    enum class TypeID {
        Void,
        Numerical,
        Pointer,
        Function,
        Struct
    };
    
private:
    const TypeID typeId;
    llvm::Type *llvmType = nullptr;
    llvm::DIType *llvmDIType = nullptr;
    PointerType *pointerTo = nullptr;

protected:
    explicit Type(TypeID typeId) : typeId(typeId) {}
    
public:
    TypeID getTypeId() const { return typeId; }
    
    llvm::Type* getLLVMType() const { return llvmType; }
    void setLLVMType(llvm::Type *ty) { llvmType = ty; }
    
    llvm::DIType* getLLVMDIType() const { return llvmDIType; }
    void setLLVMDIType(llvm::DIType *ty) { llvmDIType = ty; }
    
    
    bool isNominalType() const;
    virtual std::string getName() const;
    virtual std::string str() const;
    
    bool isVoidTy() const { return typeId == TypeID::Void; }
    bool isPointerTy() const { return typeId == TypeID::Pointer; }
    bool isNumericalTy() const { return typeId == TypeID::Numerical; }
    bool isFunctionTy() const { return typeId == TypeID::Function; }
    bool isStructTy() const { return typeId == TypeID::Struct; }
    
    PointerType* getPointerTo();

    
    static void initPrimitives();
    
    static Type* getVoidType();
    static NumericalType* getBoolType();
    static NumericalType* getInt8Type();
    static NumericalType* getInt16Type();
    static NumericalType* getInt32Type();
    static NumericalType* getInt64Type();
    static NumericalType* getUInt8Type();
    static NumericalType* getUInt16Type();
    static NumericalType* getUInt32Type();
    static NumericalType* getUInt64Type();
    static NumericalType* getFloat64Type(); // An IEEE 754 binary64 floating point type
};



class NumericalType : public Type {
    friend class Type;
public:
    enum class NumericalTypeID {
        Int8, Int16, Int32, Int64,
        UInt8, UInt16, UInt32, UInt64,
        Float64, Bool
    };
    
private:
    const NumericalTypeID numericalTypeId;
    explicit NumericalType(NumericalTypeID typeId) : Type(Type::TypeID::Numerical), numericalTypeId(typeId) {}
    
public:
    NumericalTypeID getNumericalTypeID() const { return numericalTypeId; }
    
    virtual std::string getName() const;
    virtual std::string str() const;
    uint8_t getSize() const;
    uint8_t getPrimitiveSizeInBits() const;
    bool isSigned() const;
    bool isIntegerTy() const;

};




class PointerType : public Type {
    friend class Type;
    
    Type *pointee;
    
    // Use Type::getPointerTo instead
    explicit PointerType(Type *pointee) : Type(Type::TypeID::Pointer), pointee(pointee) {}
    
public:
    virtual std::string getName() const;
    virtual std::string str() const;
    Type* getPointee() const { return pointee; }
};




class FunctionType : public Type {
    friend class Type;
    
    Type *returnType;
    std::vector<Type *> parameterTypes;
    CallingConvention callingConvention;
    
    FunctionType(Type *retTy, std::vector<Type *> paramTys, CallingConvention cc)
    : Type(Type::TypeID::Function), returnType(retTy), parameterTypes(paramTys), callingConvention(cc) {}
    
public:
    virtual std::string getName() const;
    virtual std::string str() const;
    
    Type* getReturnType() const { return returnType; }
    uint64_t getNumberOfParameters() const { return parameterTypes.size(); }
    const std::vector<Type *>& getParameterTypes() const { return parameterTypes; }
    CallingConvention getCallingConvention() const { return callingConvention; }
    
    static FunctionType* create(Type *returnType, std::vector<Type *> parameterTypes, CallingConvention cc) {
        return new FunctionType(returnType, parameterTypes, cc);
    }
};





class StructType : public Type {
    friend class Type;
public:
    using MembersT = std::vector<std::pair<std::string, Type *>>;

private:
    std::string name;
    MembersT members;
    
    StructType(std::string name, MembersT members) : Type(Type::TypeID::Struct), name(name), members(members) {}
    
public:
    
    virtual std::string getName() const;
    virtual std::string str() const;
    
    bool hasMember(const std::string &name) const;
    
    // Returns a tuple containing the members index and type
    // Returns {0, nullptr} if the struct does not have a member with this name
    std::pair<uint64_t, Type*> getMember(const std::string &name) const;
    const MembersT& getMembers() const { return members; }
    
    
    static StructType* create(std::string name, MembersT members) {
        return new StructType(name, members);
    }
};


NS_END

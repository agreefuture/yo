//
//  Attributes.cpp
//  yo
//
//  Created by Lukas Kollmer on 2019-02-24.
//  Copyright © 2019 Lukas Kollmer. All rights reserved.
//

#include "Attributes.h"
#include "util.h"
#include <optional>

using namespace yo::attributes;


namespace attr_vec_utils {
    std::optional<Attribute> get_with_key(const std::vector<Attribute> &attributes, std::string_view key) {
        return yo::util::vector::first_where(attributes, [&key](auto &attr) { return attr.getKey() == key; });
    }
    
    bool contains_key(const std::vector<Attribute> &attributes, std::string_view key) {
        return get_with_key(attributes, key).has_value();
    }
}


#define ATTRIBUTE(scope, name) \
namespace builtin_attributes::scope::name { const std::string_view _yo_attr_key = #name; }

#define ATTR_MEMBER(scope, attr_name, member_name) \
namespace builtin_attributes::scope::attr_name { const std::string_view member_name = #member_name; }

#pragma mark - Function Attributes

ATTRIBUTE(function, no_mangle)
ATTRIBUTE(function, intrinsic)
ATTRIBUTE(function, variadic)
ATTRIBUTE(function, arc)
ATTRIBUTE(function, mangle)
ATTRIBUTE(function, side_effects)

ATTR_MEMBER(function, side_effects, none)
ATTR_MEMBER(function, side_effects, io)
ATTR_MEMBER(function, side_effects, unknown)



std::vector<SideEffect> HandleSideEffectsAttribute(const Attribute &attribute) {
    precondition(attribute.key == builtin_attributes::function::side_effects::_yo_attr_key);
    
    auto values = std::get<std::vector<std::string>>(attribute.data);
    std::vector<SideEffect> sideEffects;
    bool containsNone = false;
    
    if (values.empty()) {
        return { SideEffect::Unknown };
    }
    
    for (auto &value : values) {
        if (value == builtin_attributes::function::side_effects::none) {
            containsNone = true;
            sideEffects.push_back(SideEffect::None);
        } else if (value == builtin_attributes::function::side_effects::io) {
            sideEffects.push_back(SideEffect::IO);
        } else {
            LKFatalError("unknown value in side_effects attribute: '%s'", value.c_str());
        }
    }
    
    assert_implication(containsNone, sideEffects.size() == 1);
    return sideEffects;
}



// Changed behaviour depending on whether F returns void or U
template <template <typename...> class container, typename T, typename U, typename F>
U reduce(const container<T> &input, U initialValue, F fn) {
    U accumulator = initialValue;
    for (auto it = input.begin(); it != input.end(); it++) {
        if constexpr(std::is_void_v<std::invoke_result_t<F, U&, const T&, uint64_t>>) {
            fn(accumulator, *it, it + 1 == input.end());
        } else {
            static_assert(std::is_same_v<U, std::invoke_result_t<F, F, const U&, const T&, uint64_t>>, "");
            accumulator = fn(accumulator, *it, it - input.begin());
        }
    }
    return accumulator;
}



void ensure_mutual_exclusivity(const std::vector<std::string_view> &attributeNames, const std::initializer_list<std::string_view> &attributesToCheckFor) {
    std::vector<std::string_view> foundAttributeNames;
    for (auto &attr_check : attributesToCheckFor) {
        if (yo::util::vector::contains(attributeNames, attr_check)) {
            foundAttributeNames.push_back(attr_check);
        }
    }
    
    if (foundAttributeNames.size() > 1) {
        auto desc2 = reduce(foundAttributeNames, std::string(), [&foundAttributeNames](std::string &acc, const std::string_view &attr_name, int64_t idx) {
            acc.append("'").append(attr_name).append("'");
            if (idx + 2 < foundAttributeNames.size()) {
                acc.append(", ");
            } else if (idx + 2 == foundAttributeNames.size()) {
                acc.append(" and ");
            }
        });
        LKFatalError("Error: the attributes %s are mutually exclusive", desc2.c_str());
    }
}





FunctionAttributes::FunctionAttributes(const std::vector<Attribute> &attributes) : FunctionAttributes() {    
    if (attributes.empty()) return;
    
    std::vector<std::string_view> handledAttributes;

    for (auto &attribute : attributes) {
        precondition(!util::vector::contains(handledAttributes, attribute.getKey()));
        handledAttributes.push_back(attribute.getKey());
        
        if (attribute.key == builtin_attributes::function::no_mangle::_yo_attr_key) {
            no_mangle = std::get<bool>(attribute.data);
            
        } else if (attribute.key == builtin_attributes::function::arc::_yo_attr_key) {
            arc = std::get<bool>(attribute.data);
        
        } else if (attribute.key == builtin_attributes::function::intrinsic::_yo_attr_key) {
            intrinsic = std::get<bool>(attribute.data);
        
        } else if (attribute.key == builtin_attributes::function::variadic::_yo_attr_key) {
            variadic = std::get<bool>(attribute.data);
        
        } else if (attribute.key == builtin_attributes::function::side_effects::_yo_attr_key) {
            side_effects = HandleSideEffectsAttribute(attribute);
            
        } else if (attribute.key == builtin_attributes::function::mangle::_yo_attr_key) {
            mangledName = std::get<std::string>(attribute.data);
            
        } else {
            LKFatalError("unknown function attribute: '%s'", attribute.key.c_str());
        }
    }
    
    ensure_mutual_exclusivity(handledAttributes, {
        builtin_attributes::function::mangle::_yo_attr_key,
        builtin_attributes::function::no_mangle::_yo_attr_key
    });
}



#pragma mark - Struct Attributes

ATTRIBUTE(structDecl, arc)
ATTRIBUTE(structDecl, no_init)


StructAttributes::StructAttributes(const std::vector<Attribute> &attributes) : StructAttributes() {
    if (attributes.empty()) return;
    
    std::vector<std::string_view> handledAttributes;
    
    for (auto &attribute : attributes) {
        precondition(!util::vector::contains(handledAttributes, attribute.getKey()));
        handledAttributes.push_back(attribute.key);
        
        if (attribute.key == builtin_attributes::structDecl::arc::_yo_attr_key) {
            arc = std::get<bool>(attribute.data);
        } else if (attribute.key == builtin_attributes::structDecl::no_init::_yo_attr_key) {
            no_init = std::get<bool>(attribute.data);
        } else {
            LKFatalError("unknown struct attribute: '%s'", attribute.key.c_str());
        }
    }
}


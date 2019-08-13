//
//  Pygmentize.h
//  yo
//
//  Created by Lukas Kollmer on 2019-07-23.
//  Copyright © 2019 Lukas Kollmer. All rights reserved.
//

#pragma once

#include "Token.h"
#include <string>

namespace yo::lex {
    std::string pygmentize(const std::vector<parser::Token> &tokens);
}
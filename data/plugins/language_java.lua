-- mod-version:4
local syntax = require "core.syntax"

-- number suffixes: Java integers take L/l, floats take F/f/D/d (no unsigned/ll)
local isuf = "[lL]?"
local fsuf = "[fFdD]?"

syntax.add {
  name = "Java",
  files = { "%.java$", "%.gradle$" },
  headers = "^#!.*[/%s]java%s*$",
  comment = "//",
  block_comment = { "/*", "*/" },
  patterns = {
    -- comments
    { pattern = "//.*",                                                     type = "comment"  },
    { pattern = { "/%*", "%*/" },                                           type = "comment"  },
    -- text blocks (Java 15+): """ ... """ with no escapes inside the delimiter
    { pattern = { '"""', '"""' },                                           type = "string"   },
    -- strings and chars
    { pattern = { '"', '"', '\\' },                                         type = "string"   },
    { pattern = { "'", "'", '\\' },                                         type = "string"   },
    -- numbers
    { regex   = "0x[0-9a-fA-F][0-9a-fA-F']*"..isuf,                          type = "number"   },
    { regex   = "0b[01][01']*"..isuf,                                        type = "number"   },
    { regex   = "0[0-7][0-7']*"..isuf,                                       type = "number"   },
    { regex   = "\\d[\\d']*\\.?\\d*(?:[Ee][-+]?\\d+)?"..fsuf,                type = "number"   },
    { regex   = "\\.\\d+(?:[Ee][-+]?\\d+)?"..fsuf,                           type = "number"   },
    -- operators
    { pattern = "[%+%-=/%*%^%%<>!~|&]",                                     type = "operator" },
    -- annotations: @ followed by an identifier (and optional .qualified args)
    { pattern = "@()[%a_][%w_]*",                                           type = { "operator", "keyword2" } },
    -- package / import statements
    { pattern = "package%s+()[%w_%.]*",                                     type = { "keyword", "keyword2" } },
    { pattern = "import%s+()[%w_%.%*]*",                                    type = { "keyword", "keyword2" } },
    -- type declarations: class/interface/enum/record <Name>
    { pattern = "[Cc]lass%s+()[%a_][%w_]*",                                 type = { "keyword", "keyword2" } },
    { pattern = "interface%s+()[%a_][%w_]*",                                type = { "keyword", "keyword2" } },
    { pattern = "enum%s+()[%a_][%w_]*",                                     type = { "keyword", "keyword2" } },
    { pattern = "record%s+()[%a_][%w_]*",                                   type = { "keyword", "keyword2" } },
    -- method declarations: <Type> <name>(  — type can be qualified/generic
    { pattern = "[%a_][%w_]*()%s*()[%a_][%w_]*%s*%f[(]",
      type = { "literal", "normal", "function" }
    },
    { pattern = "[%a_][%w_]*()%s+()[%a_][%w_]*%f[(]",
      type = { "literal", "normal", "function" }
    },
    -- variable declarations: <Type> <name>;
    { pattern = "[%a_][%w_]*()%s+()[%a_][%w_]*()%s*()[;,%[%)]",
      type = { "literal", "normal", "normal", "normal", "normal" }
    },
    -- all other functions
    { pattern = "[%a_][%w_]*%f[(]",                                        type = "function" },
    -- Uppercase constants (ALL_CAPS, at least 2 chars)
    { pattern = "_?%u[%u_][%u%d_]*%f[%s%+%*%-%.%)%]}%?%^%%=/<>~|&;:,!]",
      type = "number"
    },
    -- Everything else
    { pattern = "[%a_][%w_]*",                                              type = "symbol"   },
  },
  symbols = {
    -- keywords
    ["abstract"]    = "keyword",
    ["assert"]      = "keyword",
    ["break"]       = "keyword",
    ["case"]        = "keyword",
    ["catch"]       = "keyword",
    ["class"]       = "keyword",
    ["const"]       = "keyword",
    ["continue"]    = "keyword",
    ["default"]     = "keyword",
    ["do"]          = "keyword",
    ["else"]        = "keyword",
    ["enum"]        = "keyword",
    ["exports"]     = "keyword",
    ["extends"]     = "keyword",
    ["final"]       = "keyword",
    ["finally"]     = "keyword",
    ["for"]         = "keyword",
    ["goto"]        = "keyword",
    ["if"]          = "keyword",
    ["implements"]  = "keyword",
    ["import"]      = "keyword",
    ["instanceof"]  = "keyword",
    ["interface"]   = "keyword",
    ["module"]      = "keyword",
    ["native"]      = "keyword",
    ["new"]         = "keyword",
    ["open"]        = "keyword",
    ["opens"]       = "keyword",
    ["package"]     = "keyword",
    ["private"]     = "keyword",
    ["protected"]   = "keyword",
    ["public"]      = "keyword",
    ["record"]      = "keyword",
    ["requires"]    = "keyword",
    ["return"]      = "keyword",
    ["sealed"]      = "keyword",
    ["static"]      = "keyword",
    ["strictfp"]    = "keyword",
    ["super"]       = "keyword",
    ["switch"]      = "keyword",
    ["synchronized"]= "keyword",
    ["this"]        = "keyword",
    ["throw"]       = "keyword",
    ["throws"]      = "keyword",
    ["to"]          = "keyword",
    ["transient"]   = "keyword",
    ["try"]         = "keyword",
    ["uses"]        = "keyword",
    ["volatile"]    = "keyword",
    ["while"]       = "keyword",
    ["with"]        = "keyword",
    ["yield"]       = "keyword",
    -- literals
    ["true"]        = "literal",
    ["false"]       = "literal",
    ["null"]        = "literal",
    -- primitive types
    ["void"]        = "keyword2",
    ["boolean"]     = "keyword2",
    ["byte"]        = "keyword2",
    ["char"]        = "keyword2",
    ["short"]       = "keyword2",
    ["int"]         = "keyword2",
    ["long"]        = "keyword2",
    ["float"]       = "keyword2",
    ["double"]      = "keyword2",
    -- var (local variable type inference, Java 10+)
    ["var"]         = "keyword2",
  },
}

// Barry Lyu, 06/06/2025
// Adapted from BRGTC6 Testing Infra by Parker Schless

`ifndef ASTRAEA_UTIL_DEFINES
`define ASTRAEA_UTIL_DEFINES

//=============================================================================
// Console colors
//=============================================================================

`define RED    "\033[31m"
`define GREEN  "\033[32m"
`define YELLOW "\033[33m"
`define BLUE   "\033[34m"
`define CYAN   "\033[36m"
`define RESET  "\033[0m"

//=============================================================================
// Common values
//=============================================================================

`define TB_CASE_DRAIN_TIME 100

//=============================================================================
// Dump VCD
//=============================================================================
`define DUMP_VCD(name, filename)                                              \
    initial begin                                                             \
        $dumpfile(filename);                                                  \
        $dumpvars(0, name);                                                   \
    end

//=============================================================================
// Test Print-out Macros
//=============================================================================

`define ERR_MSG  $write("\033[31m[ERROR]\033[0m ")
`define WARN_MSG $write("\033[33m[WARN]\033[0m ")
`define INFO_MSG $write("\033[34m[INFO]\033[0m ")

`define LOC_MSG $write("%s:%0d: ", `__FILE__, `__LINE__)

`define PRINT_BANNER(color)                                                  \
    $display("%s========================================%s",                 \
             color, `RESET);

`define PRINT_LINE(color)                                                    \
    $display("%s----------------------------------------%s",                 \
             color, `RESET);


`define PRINT_CHECK                                                          \
    if ($test$plusargs("verbose")) $display(`GREEN, "PASSED", `RESET);       \
    else $write(`GREEN, ".", `RESET);

`define PRINT_TIMEOUT                                                        \
     if ($test$plusargs("verbose")) $display(`RED, "TIMEOUT", `RESET);       \
    else $write(`RED, "T", `RESET);

`define PRINT_PASSED                                                         \
    $display("\n\n%s[TEST PASSED]%s\n", `GREEN, `RESET);

`define PRINT_FAILED                                                         \
    $display("\n\n%s[TEST FAILED]%s\n", `RED, `RESET); 

task automatic TEST_CASE(input string test);
    $display(`CYAN,"\n\nRunning [%s]", test,`RESET);
    `PRINT_BANNER(`CYAN);
endtask

`define CHECK_BITS(bits, exp, err_msg)                                      \
    if( exp !== (exp ^ bits ^ exp) ) begin                                  \
        `ERR_MSG;                                                           \
        $display("Check failed. Expected: %h, Received: %h", exp, bits);    \
        $display("%s", err_msg);                                            \
        $fatal;                                                             \
    end else begin                                                          \
        `PRINT_CHECK;                                                       \
    end


`endif // ASTRAEA_UTIL_DEFINES


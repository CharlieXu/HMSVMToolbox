#!/bin/tcsh

setenv CPLEX_LIB /fml/ag-raetsch/share/software/ilog/cplex90/lib/x86-64_RHEL3.0_3.2/static_pic/
setenv CPLEX_INC /fml/ag-raetsch/share/software/ilog/cplex90/include/ilcplex

/fml/ag-raetsch/share/software/matlab/bin/mex -I$CPLEX_INC -L$CPLEX_LIB -lcplex -lpthread -largeArrayDims cplex_init_quit.c
/fml/ag-raetsch/share/software/matlab/bin/mex -I$CPLEX_INC -L$CPLEX_LIB -lcplex -lpthread -largeArrayDims opt_set_param.c
/fml/ag-raetsch/share/software/matlab/bin/mex -I$CPLEX_INC -L$CPLEX_LIB -lcplex -lpthread -largeArrayDims lp_solve.c
/fml/ag-raetsch/share/software/matlab/bin/mex -I$CPLEX_INC -L$CPLEX_LIB -lcplex -lpthread -largeArrayDims qp_solve.c


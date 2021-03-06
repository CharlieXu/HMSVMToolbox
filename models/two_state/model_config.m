function config = model_config()

% config = model_config()
%
% Returns a struct representing the model configuration,
% mostly model-specific function names to be called via feval.m.
%
% written by Georg Zeller, MPI Tuebingen, Germany, 2007-2008

config.name = 'two_state';
  
config.func_get_label_set    = 'get_label_set';
config.func_get_state_set    = 'get_state_set';
config.func_make_model       = 'make_model';
config.func_labels_to_states = 'labels_to_states';
config.func_states_to_labels = 'states_to_labels';
config.func_init_parameters  = 'init_parameters';
config.func_calc_loss_matrix = 'calc_loss_matrix';

config.func_view_model       = 'view_model';
config.func_view_label_seqs  = 'view_label_seqs';

% eof

function progress = train_hmsvm(PAR)

% progress = train_hmsvm(PAR)
%
% Main script for HM-SVM training.
%
% PAR -- a struct to configure the HM-SVM (for specification see model_sel.m)
% returns a struct recording the training progress
%
% written by Georg Zeller & Gunnar Raetsch, MPI Tuebingen, Germany, 2008

% path to the Shogun toolbox needed for Viterbi decoding
addpath /fml/ag-raetsch/share/software/matlab_tools/shogun
% path to cplex optimizer interface needed to solve training problems
addpath /fml/ag-raetsch/share/software/matlab_tools/cplex9 %10

% option to enable/disable some extra consistency checks
EXTRA_CHECKS = 1;

% option to control the amount of output
VERBOSE = 1;
if VERBOSE>=1,
  fh1 = figure;
end

% stopping criterion: constraint generation is terminated if no more
% margin violations are found or the relative change of the objective
% function is smaller than this parameter
MIN_REL_OBJ_CHANGE = 10^-3;
% or if the maximum number of iterations is exceeded
MAX_NUM_ITER = 100;

% margin constraints are only added if the example is predicted with an
% accuracy below this parameter
MAX_ACCURACY = 0.99;

% numerical tolerance to check consistent score calculation, constraint
% satisfaction and monotonictiy of the objective function
EPSILON = 10^-6;

% seed for random number generation
rand('seed', 11081979);

% mandatory fields of the parameter struct
assert(isfield(PAR, 'C_small'));
assert(isfield(PAR, 'C_smooth'));
assert(isfield(PAR, 'C_coupling'));
assert(isfield(PAR, 'num_exm'));
assert(isfield(PAR, 'data_file'));
assert(isfield(PAR, 'out_dir'));
assert(isfield(PAR, 'model_dir'));
assert(isfield(PAR, 'optimization'));
assert(isfield(PAR, 'train_subsets'));

if ~exist(PAR.out_dir, 'dir'),
  mkdir(PAR.out_dir);
end

%%%%% init state model
if exist(PAR.model_name)~=7,
  addpath(PAR.model_dir);
end
PAR.model_config = model_config();
assert(isequal(PAR.model_name, PAR.model_config.name));
disp(PAR);
disp(PAR.data_file);


%%%%% load data and select training examples
data = load(PAR.data_file, 'pos_id', 'label', 'signal', 'exm_id', 'subset_id');
PAR.train_idx = find(ismember(data.subset_id, PAR.train_subsets));
train_exm_ids = unique(data.exm_id(PAR.train_idx));
PAR.vald_idx = find(ismember(data.subset_id, PAR.vald_subsets));
vald_exm_ids = unique(data.exm_id(PAR.vald_idx));

pos_id      = data.pos_id;
label       = data.label;
signal      = data.signal;
exm_id      = data.exm_id;
state_label = nan(size(label));
clear data

PAR.num_features = size(signal,1);

% randomize order of potential training example before subselection
r_idx = randperm(length(train_exm_ids));
train_exm_ids = train_exm_ids(r_idx);
% for validation use validation sets and unused training examples
holdout_exm_ids = train_exm_ids(PAR.num_exm+1:end);
holdout_exm_ids = [holdout_exm_ids vald_exm_ids];
% subselect PAR.num_exm sequences for training
train_exm_ids = train_exm_ids(1:PAR.num_exm);
assert(isempty(intersect(train_exm_ids, holdout_exm_ids)));
fprintf('\nusing %i sequences for training.\n', ...
        length(train_exm_ids));
fprintf('using %i sequences for performance estimation.\n\n', ...
        length(holdout_exm_ids));


%%%%% assemble model and score function structs,
LABELS = eval(sprintf('%s;', ...
                      PAR.model_config.func_get_label_set));
state_model = eval(sprintf('%s(PAR);', ...
                           PAR.model_config.func_make_model));

[score_plifs transition_scores] = eval(sprintf('%s(signal, label, state_model, PAR);', ...
                                               PAR.model_config.func_init_parameters));
assert(~any(isnan([score_plifs.limits])));
assert(~any(isnan([score_plifs.scores])));
assert(~any(isnan(transition_scores)));

%%% determine the true state sequence for each example from its label sequence
for i=1:length(train_exm_ids),
  idx = find(exm_id==train_exm_ids(i));
  true_label_seq = label(idx);
  obs_seq = signal(:,idx);
  true_state_seq = eval(sprintf('%s(true_label_seq, state_model, obs_seq, PAR);', ...
                                PAR.model_config.func_labels_to_states));
  if EXTRA_CHECKS,
    assert(check_path(true_state_seq, state_model));
  end
  state_label(idx) = true_state_seq;
end

%%%%% inititialize optimization problem 
lpenv = cplex_license(1);
switch PAR.optimization,
 case 'QP',
  [A b Q f lb ub slacks res res_map PAR] ...
      = init_QP(transition_scores, score_plifs, state_model, PAR);
 case 'LP',
  [A b f lb ub slacks res res_map PAR] ...
      = init_LP(transition_scores, score_plifs, state_model, PAR);
  how = lp_set_param(lpenv, 'CPX_PARAM_PREDUAL', 1, 1);
  assert(isequal(how, 'OK'));
  Q = []; % just to keep code as general as possible
 otherwise,
  error(sprintf('unknown optimization: %s', PAR.optimization));
end
assert(length(res) == PAR.num_opt_var);
assert(all(size(res_map) == size(score_plifs)));


%%%%% start iterative training
% a struct keeping track of training progress
progress = [];
% accuracy on training examples
trn_acc = zeros(1,length(train_exm_ids));
% accuracy on holdout validation examples
val_acc = zeros(1,length(holdout_exm_ids));
% previous value of the objective function
last_obj = 0;
% record elapsed time
t_start = clock();

for iter=1:MAX_NUM_ITER,
  new_constraints = zeros(1,PAR.num_exm);
  tic
  for i=1:length(train_exm_ids),
    idx = find(exm_id==train_exm_ids(i));
    obs_seq = signal(:,idx);
    true_label_seq = label(idx);
    true_state_seq = state_label(idx);
    
    %%%%% Viterbi decoding
    [pred_path true_path pred_path_mmv] ...
        = decode_Viterbi(obs_seq, transition_scores, score_plifs, ...
                         PAR, true_label_seq, true_state_seq);
    if EXTRA_CHECKS,
      w = weights_to_vector(pred_path.transition_weights, ...
                            pred_path.plif_weights, state_model, ...
                            res_map, PAR);
      assert(abs(w*res(1:PAR.num_param) - pred_path.score) < EPSILON);
  
      w = weights_to_vector(pred_path_mmv.transition_weights, ...
                            pred_path_mmv.plif_weights, state_model, ...
                            res_map, PAR);
      assert(abs(w*res(1:PAR.num_param) - pred_path_mmv.score) < EPSILON);
    end
    trn_acc(i) = mean(true_path.label_seq==pred_path.label_seq);

    w_p = weights_to_vector(true_path.transition_weights, ...
                            true_path.plif_weights, state_model, ...
                            res_map, PAR);
    w_n = weights_to_vector(pred_path_mmv.transition_weights, ...
                            pred_path_mmv.plif_weights, state_model, ...
                            res_map, PAR);
    weight_delta = w_p - w_n;
    assert(length(weight_delta) == PAR.num_param);

    loss = sum(pred_path_mmv.loss);
    if norm(weight_delta)==0, assert(loss < EPSILON); end

    score_delta = weight_delta*res(1:PAR.num_param);
    
    %%%%% add constraints for examples which have not been decoded correctly
    %%%%% and for which a margin violator has been found
    if score_delta + slacks(i) < loss - EPSILON && trn_acc(i)<MAX_ACCURACY,
      v = zeros(1,PAR.num_exm);
      v(i) = 1;
      A = [A; -weight_delta zeros(1, PAR.num_aux) -v];
      b = [b; -loss];
      new_constraints(i) = 1;      
    end
    
    if VERBOSE>=2,
      fprintf('Training example %i\n', train_exm_ids(i));      
      fprintf('  example accuracy: %3.2f%%\n', 100*trn_acc(i));
      fprintf('  loss = %6.2f  diff = %8.2f  slack = %6.2f\n', ...
              loss, score_delta, slacks(i));
      if new_constraints(i),
        fprintf('  generated new constraint\n', train_exm_ids(i));      
      end
    end
  end
  fprintf('Generated %i new constraints\n\n', sum(new_constraints));
  fprintf('Constraint generation took %3.2f sec\n\n', toc);

  %%%%% solve intermediate optimization problem
  tic
  switch PAR.optimization,
   case 'QP',
    [res, lambda, how] = qp_solve(lpenv, Q, f, sparse(A), b, lb, ub, 0, 1, 'bar');
    if ~isequal(how, 'OK'),
      error(sprintf('Optimizer problem: %s', how));
    end
    obj = 0.5*res'*Q*res + f'*res;
   case 'LP',
    [res, lambda, how] = lp_solve(lpenv, f, sparse(A), b, lb, ub, 0, 1, 'bar');
    if ~isequal(how, 'OK'),
      error(sprintf('Optimizer problem: %s', how));
    end
    obj = f'*res;
   otherwise,
    error(sprintf('unknown optimization: %s', PAR.optimization));
  end
  fprintf('\nSolving the optimization problem took %3.2f sec\n', toc);
  assert(length(res) == PAR.num_param+PAR.num_aux+PAR.num_exm);
  slacks = res(end-PAR.num_exm+1:end);
  diff = obj - last_obj;
  % error if objective is not monotonically increasing
  if diff < -EPSILON,
    error(sprintf('decrease in objective function %f by %f', obj, diff));
  end
  last_obj = obj;
  fprintf('  objective = %1.6f (diff = %1.6f), sum_slack = %1.6f\n\n', ...
          obj, diff, sum(slacks));

  %%%%% extract parameters from optimization problem & update model 
  %%%%% (i.e. transition scores & score PLiFs)
  [transition_scores, score_plifs] = res_to_scores(res, state_model, res_map, ...
                                                   score_plifs, PAR);
  
  %%%%% check prediction accuracy on training examples
  for j=1:length(train_exm_ids),
    trn_idx = find(exm_id==train_exm_ids(j));
    trn_obs_seq = signal(:,trn_idx);
    trn_pred_path = decode_Viterbi(trn_obs_seq, transition_scores, score_plifs, PAR);
    trn_true_label_seq = label(trn_idx);
    trn_pred_label_seq = trn_pred_path.label_seq;
    trn_acc(j) = mean(trn_true_label_seq(1,:)==trn_pred_label_seq(1,:));

    if VERBOSE>=2 && iter>=15 && j<=25,
      view_label_seqs(gcf, trn_obs_seq, trn_true_label_seq, trn_pred_label_seq);
      title(gca, ['Training example ' num2str(train_exm_ids(j))]);
      fprintf('Training example %i\n', train_exm_ids(j));
      fprintf('  Example accuracy: %3.2f%%\n', 100*trn_acc(j));
      pause
    end
  end
  fprintf(['\nIteration %i:\n' ...
           '  LSL training accuracy:              %2.2f%%\n'], ...
          iter, 100*mean(trn_acc));
  
  %%%%% check prediction accuracy on holdout examples
  for j=1:length(holdout_exm_ids),
    val_idx = find(exm_id==holdout_exm_ids(j));
    val_obs_seq = signal(:,val_idx);
    val_pred_path = decode_Viterbi(val_obs_seq, transition_scores, score_plifs, PAR);
    val_true_label_seq = label(val_idx);
    val_pred_label_seq = val_pred_path.label_seq;
    val_acc(j) = mean(val_true_label_seq(1,:)==val_pred_label_seq(1,:));
    
    if VERBOSE>=2 && iter>=15 && j<=25,
      view_label_seqs(gcf, val_obs_seq, val_true_label_seq, val_pred_label_seq);
      title(gca, ['Hold-out example ' num2str(holdout_exm_ids(j))]);
      fprintf('Hold-out example %i\n', holdout_exm_ids(j));
      fprintf('  Example accuracy: %3.2f%%\n', 100*val_acc(j));
      pause
    end
  end
  fprintf(['  LSL validation accuracy:            %2.2f%%\n\n'], ...
          iter, 100*mean(val_acc));
  
  if VERBOSE>=2 && iter>=20,
    fhs = eval(sprintf('%s(state_model, score_plifs, transition_scores);', ...
                       PAR.model_config.func_view_model));
    keyboard
  end  

  progress(iter).trn_acc = trn_acc';
  progress(iter).val_acc = val_acc';
  progress(iter).gen_constraints = new_constraints';
  progress(iter).objective = obj;
  progress(iter).el_time = etime(clock(), t_start);
  
  % save at every fifth iteration anyway
  if  mod(iter,5)==0,
    fprintf('Saving result...\n\n\n');
    fname = sprintf('lsl_iter%i', iter);
    save([PAR.out_dir fname], 'PAR', 'score_plifs', 'transition_scores', ...
         'trn_acc', 'val_acc', 'A', 'b', 'Q', 'f', 'lb', 'ub', 'slacks', 'res', ...
         'train_exm_ids', 'holdout_exm_ids', 'progress');
  end
  
  if VERBOSE>=1,
    plot_progress(progress, fh1);
    pause(1);
  end    
  
  % save and terminate training if no more constraints are generated or
  % the change of the objective function was unsubstantial
  if all(new_constraints==0) || diff < obj*MIN_REL_OBJ_CHANGE,
    fprintf('Saving result...\n\n\n');
    fname = sprintf('lsl_final');
    save([PAR.out_dir fname], 'PAR', 'score_plifs', 'transition_scores', ...
         'trn_acc', 'val_acc', 'A', 'b', 'Q', 'f', 'lb', 'ub', 'slacks', 'res', ...
         'train_exm_ids', 'holdout_exm_ids', 'progress');
   
    if VERBOSE>=2,
      figure
      eval(sprintf('%s(state_model, score_plifs, transition_scores);', ...
                   PAR.model_config.func_view_model));
      figure
      plot(res)
      keyboard
    end

    % terminate
    return
  end
end
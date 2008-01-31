function main_training(PAR)
% main_training(PAR)
% For parameter specification (PAR) see model_sel.m.

% written by Georg Zeller & Gunnar Raetsch, MPI Tuebingen, Germany

addpath /fml/ag-raetsch/share/software/matlab_tools/shogun
addpath /fml/ag-raetsch/share/software/matlab_tools/cplex9


EXTRA_CHECKS = 0;
VERBOSE = 0

MAX_ACCURACY = 1; % 0.99;
EPSILON = 10^-5;

assert(isfield(PAR, 'C_small'));
assert(isfield(PAR, 'C_smooth'));
assert(isfield(PAR, 'C_coupling'));
assert(isfield(PAR, 'num_exm'));
assert(isfield(PAR, 'data_file'));
assert(isfield(PAR, 'out_dir'));
assert(isfield(PAR, 'model_dir'));

if ~isfield(PAR, 'train_subsets'),
  PAR.train_subsets = [1 2 3];
  PAR.vald_subsets  = [4];
  PAR.test_subsets  = [5];
end

if ~exist(PAR.out_dir, 'dir'),
  mkdir(PAR.out_dir);
end

%%%%% init state model
addpath(PAR.model_dir);
PAR.model_config = model_config();

name = separate(PAR.model_dir, '/');
name(strmatch('', name, 'exact')) = [];
name = name{end};
assert(isequal(PAR.model_config.name, name));

disp(PAR);
disp(PAR.data_file);


%%%%% load data and select training examples
rand('seed', 11081979);

data = load(PAR.data_file, 'pos_id', 'label', 'signal', 'exm_id', 'subset_id');
PAR.train_idx = find(ismember(data.subset_id, PAR.train_subsets));
train_exm_ids = unique(data.exm_id(PAR.train_idx));
PAR.vald_idx = find(ismember(data.subset_id, PAR.vald_subsets));
vald_exm_ids = unique(data.exm_id(PAR.vald_idx));

pos_id = data.pos_id;
label  = data.label;
signal = data.signal;
exm_id = data.exm_id;
clear data

PAR.num_features = size(signal,1);

r_idx = randperm(length(train_exm_ids));
train_exm_ids = train_exm_ids(r_idx);
% for validation use validation sets and unused training examples
holdout_exm_ids = train_exm_ids(PAR.num_exm+1:end);
holdout_exm_ids = [holdout_exm_ids vald_exm_ids];
% use only PAR.num_exm for training
train_exm_ids = train_exm_ids(1:PAR.num_exm);
assert(isempty(intersect(train_exm_ids, holdout_exm_ids)));
fprintf('\nusing %i sequences for training.\n', ...
        length(train_exm_ids));
fprintf('using %i sequences for performance estimation.\n\n', ...
        length(holdout_exm_ids));


%%%%% assemble model and score function structs, inititialize QP
LABELS = get_label_set;
STATES = eval(sprintf('%s();', ...
                      PAR.model_config.func_get_state_set));
[transitions, a_trans] = eval(sprintf('%s();', ...
                      PAR.model_config.func_make_model));
num_transitions = size(transitions,1);
transition_scores = randn(num_transitions,1);
assert(~any(isnan(transition_scores)));
assert(all(all(~isnan(transitions))));
assert(all(all(~isnan(a_trans))));

score_plifs = eval(sprintf('%s(signal, label, STATES, PAR);', ...
                                   PAR.model_config.func_init_parameters));
assert(~any(isnan([score_plifs.limits])));
assert(~any(isnan([score_plifs.scores])));

[A b Q f lb ub slacks res num_param] ...
    = eval(sprintf('%s(transition_scores, score_plifs, STATES, PAR);', ...
                   PAR.model_config.func_init_QP));
lpenv = cplex_license(1);


%%%%% start iterative training
trn_acc = zeros(1,length(train_exm_ids));
max_trn_acc = 0;
val_acc = zeros(1,length(holdout_exm_ids));

last_obj = 0;
num_iter = 100;
for iter=1:num_iter,
  new_constraints = zeros(1,PAR.num_exm);
  tic
  for i=1:length(train_exm_ids),
    idx = find(exm_id==train_exm_ids(i));
    obs_seq = signal(:,idx);
    true_label_seq = label(idx);
    
    %%%%% Viterbi decoding
    [pred_path true_path pred_path_mmv] ...
        = decode_Viterbi(obs_seq, transition_scores, score_plifs, ...
                         PAR, true_label_seq);
    if EXTRA_CHECKS,
      w = pred_path.transition_weights;
      for t=1:size(score_plifs,1), % for all features
        for s=1:size(score_plifs,2), % for all states
          w = [w squeeze(pred_path.plif_weights(t,s,:))'];
        end
      end
      assert(abs(w*res(1:num_param) - pred_path.score) < EPSILON);
      
      w = pred_path_mmv.transition_weights;
      for t=1:size(score_plifs,1), % for all features
        for s=1:size(score_plifs,2), % for all states
          w = [w squeeze(pred_path_mmv.plif_weights(t,s,:))'];
        end
      end
      assert(abs(w*res(1:num_param) - pred_path_mmv.score) < EPSILON);
    end
    
    trn_acc(i) = mean(true_path.label_seq==pred_path.label_seq);
    
    loss = sum(pred_path_mmv.loss);

    weight_delta = [true_path.transition_weights ...
                    - pred_path_mmv.transition_weights];
    for t=1:size(score_plifs,1), % for all features
      for s=1:size(score_plifs,2), % for all states
        weight_delta = [weight_delta, ...
                        [squeeze(true_path.plif_weights(t,s,:))' ...
                        - squeeze(pred_path_mmv.plif_weights(t,s,:))']];
      end
    end
    assert(length(weight_delta) == length(res)-PAR.num_exm);
    assert(length(weight_delta) == length(res)-PAR.num_exm);
    if norm(weight_delta)==0, assert(loss < EPSILON); end

    score_delta = weight_delta*res(1:num_param);

    
    %%%%% add constraints for examples which have not been decoded correctly
    %%%%% and for which a margin violator has been found
    if score_delta + slacks(i) < loss - EPSILON && trn_acc(i)<MAX_ACCURACY,
      v = zeros(1,PAR.num_exm);
      v(i) = 1;
      A = [A; -weight_delta -v];
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
      if mod(iter,15)==0,
        view_label_seqs(gcf, obs_seq, true_label_seq, pred_path.label_seq, pred_path_mmv.label_seq);
        title(gca, ['Training example ' num2str(train_exm_ids(i))]);
        pause
      end
    end
  end
  fprintf(['\nIteration %i:\n' ...
           '  LSL training accuracy:              %2.2f%%\n\n'], ...
          iter, 100*mean(trn_acc));
  fprintf('Generated %i new constraints\n\n', sum(new_constraints));
  fprintf('Constraint generation took %3.2f sec\n\n', toc);

  % save intermediate result if accuracy is higher than before
  % save at every fifth iteration anyway
  if mean(trn_acc)>max_trn_acc | mod(iter,1)==0,
    max_trn_acc = max(mean(trn_acc), max_trn_acc);
    fprintf('Saving result...\n\n\n');
    fname = sprintf('lsl_iter%i', iter);
    save([PAR.out_dir fname], 'PAR', 'score_plifs', 'transition_scores', 'trn_acc', ...
         'val_acc', 'A', 'b', 'Q', 'f', 'lb', 'ub', 'slacks', 'res', 'num_param', ...
         'train_exm_ids', 'holdout_exm_ids');
  end
  
  %%%%% solve intermediate QP
  tic
  [res, lambda, how] = qp_solve(lpenv, Q, f, sparse(A), b, lb, ub, 0, 1, 'bar');
  slacks = res(num_param+1:end);
  obj = 0.5*res'*Q*res + res'*f;
  diff = obj - last_obj;
  % output warning if objective is not monotonically increasing
  if diff < -EPSILON,
    warning(sprintf('decrease in objective function %f by %f', obj, diff));
    keyboard
  end
  
  last_obj = obj;
  fprintf('objective = %1.6f (diff = %1.6f), sum_slack = %1.6f\n\n', ...
          obj, diff, sum(slacks));

  %%%%% extract parameters from QP & update model 
  %%%%% (i.e. transition scores & score PLiFs)
  transition_scores = res(1:num_transitions);
  q = num_transitions;
  for t=1:size(score_plifs,1), % for all features
    for s=1:size(score_plifs,2), % for all states
      score_plifs(t,s).scores = res(q+1:q+PAR.num_plif_nodes)';
      q = q + PAR.num_plif_nodes;
    end
  end
  assert(length(res) == q+PAR.num_exm);
  fprintf('Solving the QP took %3.2f sec\n\n', toc);
  
  %%%%% check prediction accuracy on holdout examples
  for j=1:length(holdout_exm_ids),
    val_idx = find(exm_id==holdout_exm_ids(j));
    val_obs_seq = signal(:,val_idx);
    val_pred_path = decode_Viterbi(val_obs_seq, transition_scores, score_plifs, PAR);
    val_true_label_seq = label(val_idx);
    val_pred_label_seq = val_pred_path.label_seq;

    val_acc(j) = mean(val_true_label_seq(1,:)==val_pred_label_seq(1,:));
    if VERBOSE>=2 && mod(iter,15)==0,
      % plot progress
      view_label_seqs(gcf, val_obs_seq, val_true_label_seq, val_pred_label_seq);
      title(gca, ['Hold-out example ' num2str(holdout_exm_ids(j))]);
      fprintf('Hold-out example %i\n', holdout_exm_ids(j));
      fprintf('  Example accuracy: %3.2f%%\n', 100*val_acc(j));
      pause
    end
  end
  fprintf(['\nIteration %i:\n' ...
           '  LSL validation accuracy:            %2.2f%%\n\n'], ...
          iter, 100*mean(val_acc));
  if VERBOSE>=2 && mod(iter,15)==0,
    fh1 = gcf;
    fhs = eval(sprintf('%s(STATES, score_plifs, transitions, transition_scores);', ...
                       PAR.model_config.func_view_model));
    keyboard
    figure(fh1);
  end  
  
  % save and terminate if objective does not change significantly
  if all(new_constraints==0) || diff < obj/10^6,
    fprintf('Saving result...\n\n\n');
    fname = sprintf('lsl_final');
    save([PAR.out_dir fname], 'PAR', 'score_plifs', 'transition_scores', 'trn_acc', ...
         'val_acc', 'A', 'b', 'Q', 'f', 'lb', 'ub', 'slacks', 'res', 'num_param', ...
         'train_exm_ids', 'holdout_exm_ids');
    keyboard
    return
  end
end

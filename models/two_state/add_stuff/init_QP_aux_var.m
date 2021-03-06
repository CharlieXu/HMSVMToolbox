function [A b Q f lb ub slacks res PAR] = init_QP(transition_scores, score_plifs, STATES, PAR)
% [A b Q f lb ub slacks res PAR] = init_QP(transition_scores, score_plifs, STATES, PAR)
% initialize QP

% written by Gunnar Raetsch & Georg Zeller, MPI Tuebingen, Germany

% optimization paramaters: 
%   i) transition scores
res = transition_scores;
num_transition = length(res);
%   ii) y-values of PLiF supporting points (feature scoring functions)
score_starts = [];
cnt = 0;
for f=1:size(score_plifs,1), % for all features
  for s=1:size(score_plifs,2), % for all states
    score_starts(cnt+1) = length(res)+1;
    assert(length(score_plifs(f,s).scores) == PAR.num_plif_nodes);
    res = [res; score_plifs(f,s).scores']; 
    cnt = cnt + 1;
  end
end
% not a real score_start, but convenient for loops 
score_starts(end+1) = length(res)+1;
num_param = length(res);
num_plif_scores = num_param-num_transition;

%   iii) auxiliary variables to implement smoothness regularizer
%        via constraints (not learning parameters per se)
aux_starts = [];
cnt = 0;
for f=1:size(score_plifs,1), % for all features
  for s=1:size(score_plifs,2), % for all states
    aux_starts(cnt+1) = length(res)+1;
    res = [res; zeros(PAR.num_plif_nodes-1,1)]; 
    cnt = cnt + 1;
  end
end
% not a real aux_start, but convenient for loops 
aux_starts(end+1) = length(res)+1;
assert(length(aux_starts) == length(score_starts));
num_aux = length(res) - num_param;

%   iv) slack variables
slacks = zeros(PAR.num_exm,1);
res = [res; slacks];
 
% quadratic regularizer to keep PLiF values small
Q = sparse(zeros(length(res)));
Q(1:num_param,1:num_param) = PAR.C_small*eye(num_param);
% quadratic regularizer to keep PLiFs smooth
Q(num_param+1:num_param+num_aux,num_param+1:num_param+num_aux) ...
    = PAR.C_smooth*eye(num_aux);

INF = 1e20;

f = [zeros(num_param+num_aux,1); ones(PAR.num_exm,1)];
lb = [-INF*ones(num_param,1); zeros(num_aux+PAR.num_exm,1)];
ub = INF*ones(length(res),1);

A = sparse(zeros(2*num_aux, length(res)));
b = zeros(2*num_aux, 1);

% constraints for auxiliary variables
cnt = 1;
for i=1:length(score_starts)-1,
  sc_idx = score_starts(i):score_starts(i+1)-1;
  aux_idx = aux_starts(i):aux_starts(i+1)-1;
  for j=1:length(sc_idx)-1,
    % bound the difference between adjacent score values from above and
    % below by an auxiliary variable (which is then regularized quadratically):
    % scr_{i,j} - scr_{i,j+1} - aux_{i,j} <= 0
    % -scr_{i,j} + scr_{i,j+1} - aux_{i,j} <= 0

    A(cnt, sc_idx(j))   =  1;
    A(cnt, sc_idx(j+1)) = -1;
    A(cnt, aux_idx(j))  = -1;
    cnt = cnt + 1;

    A(cnt, sc_idx(j))   = -1;
    A(cnt, sc_idx(j+1)) =  1;
    A(cnt, aux_idx(j))  = -1;
    cnt = cnt + 1;
  end 
end

PAR.num_trans_score = length(transition_scores);
PAR.num_param       = num_param;
PAR.num_aux         = num_aux;
PAR.num_opt_var     = num_param+num_aux+PAR.num_exm;


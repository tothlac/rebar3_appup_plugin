-module(rebar3_appup_generate).

-export([init/1,
         do/1,
         format_error/1]).

-define(PROVIDER, generate).
-define(DEPS, []).

-define(APPUPFILEFORMAT, "%% appup generated for ~p by rebar3_appup_plugin (~p)~n"
        "{~p, [{~p, ~p}], [{~p, []}]}.~n").
-define(DEFAULT_RELEASE_DIR, "rel").

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
            {name, ?PROVIDER},            % The 'user friendly' name of the task
            {namespace, appup},
            {module, ?MODULE},            % The module implementation of the task
            {bare, true},                 % The task can be run by the user, always true
            {deps, ?DEPS},                % The list of dependencies
            {opts, [                      % list of options understood by the plugin
                {previous, $p, "previous", string, "location of the previous release"},
                {previous_version, $p, "previous_version", string, "version of the previous release"},
                {current, $c, "current", string, "location of the current release"},
                {target_dir, $t, "target_dir", string, "target dir in which to generate the .appups to"}
            ]},
            {example, "rebar3 appup generate"},
            {short_desc, "Compare two different releases and generate the .appup file"},
            {desc, "Appup generator"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    {Opts, _} = rebar_state:command_parsed_args(State),
    rebar_api:debug("opts: ~p~n", [Opts]),

    RelxConfig = rebar_state:get(State, relx, []),
    {release, {Name0, _Ver}, _} = lists:keyfind(release, 1, RelxConfig),
    Name = atom_to_list(Name0),
    rebar_api:debug("release name: ~p", [Name]),

    %% previous is a mandatory option
    PreviousRelPath = case proplists:get_value(previous, Opts, undefined) of
                        undefined -> rebar_api:abort("please specify the previous release full path", []);
                        P -> P
                      end,
    CurrentRelPath = case proplists:get_value(current, Opts, undefined) of
                        undefined -> filename:join([rebar_dir:base_dir(State),
                                                    ?DEFAULT_RELEASE_DIR,
                                                    Name]);
                        Path -> Path
                     end,
    TargetDir = proplists:get_value(target_dir, Opts, undefined),
    rebar_api:debug("previous release: ~p~n", [PreviousRelPath]),
    rebar_api:debug("current release: ~p~n", [CurrentRelPath]),
    rebar_api:debug("target dir: ~p~n", [TargetDir]),

    %% deduce the previous version from the release path
    {PreviousName, PreviousVer0} = rebar3_appup_rel_utils:get_rel_release_info(
                                            Name, PreviousRelPath),
    %% if a specific one was requested use that instead
    PreviousVer = case proplists:get_value(previous_version, Opts, undefined) of
                    undefined -> PreviousVer0;
                    V -> V
                  end,
    rebar_api:debug("previous release, name: ~p, version: ~p",
        [PreviousName, PreviousVer]),
    {CurrentName, CurrentVer} = rebar3_appup_rel_utils:get_rel_release_info(
                                            Name, CurrentRelPath),
    rebar_api:debug("previous release, name: ~p, version: ~p",
        [CurrentName, CurrentVer]),

    ModDeps = [],

    %% Run some simple checks
    true = rebar3_appup_utils:prop_check(CurrentVer =/= PreviousVer,
                      "current (~p) and previous (~p) .rel versions match",
                      [CurrentVer, PreviousVer]),
    true = rebar3_appup_utils:prop_check(CurrentName == PreviousName,
                      "current (~p) and previous (~p) release names do not match",
                      [CurrentName, PreviousName]),

    %% Find all the apps that have been upgraded
    {_Added, _Removed, Upgraded} = get_apps(Name,
                                            PreviousRelPath, PreviousVer,
                                            CurrentRelPath, CurrentVer),

    %% Get a list of any appup files that exist in the current release
    CurrentAppUpFiles = rebar3_appup_utils:find_files_by_ext(
                            filename:join([CurrentRelPath, "lib"]), ".appup"),

    %% Convert the list of appup files into app names
    CurrentAppUpApps = [file_to_name(File) || File <- CurrentAppUpFiles],
    rebar_api:debug("apps that already have .appups: ~p", [CurrentAppUpApps]),

    %% Create a list of apps that don't already have appups
    UpgradeApps = gen_appup_which_apps(Upgraded, CurrentAppUpApps),
    rebar_api:debug("generating .appup for apps: ~p", [UpgradeApps]),

    %% Generate appup files for upgraded apps
    generate_appup_files(TargetDir,
                         CurrentRelPath, PreviousRelPath,
                         ModDeps, UpgradeApps,
                         State),

    {ok, State}.

-spec format_error(any()) ->  iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

%% ===================================================================
%% Private API
%% ===================================================================
get_apps(Name, OldVerPath, OldVer, NewVerPath, NewVer) ->
    OldApps = rebar3_appup_rel_utils:get_rel_apps(Name, OldVer, OldVerPath),
    rebar_api:debug("previous version apps: ~p~n", [OldApps]),

    NewApps = rebar3_appup_rel_utils:get_rel_apps(Name, NewVer, NewVerPath),
    rebar_api:debug("current version apps: ~p~n", [NewApps]),

    Added = app_list_diff(NewApps, OldApps),
    rebar_api:debug("added: ~p~n", [Added]),

    Removed = app_list_diff(OldApps, NewApps),
    rebar_api:debug("removed: ~p~n", [Removed]),

    PossiblyUpgraded = proplists:get_keys(NewApps),

    UpgradedApps = [upgraded_app(AppName,
                                 proplists:get_value(AppName, OldApps),
                                 proplists:get_value(AppName, NewApps))
                    || AppName <- PossiblyUpgraded],

    Upgraded = lists:dropwhile(fun(Elem) ->
                                       Elem == false
                               end, lists:sort(UpgradedApps)),

    rebar_api:debug("upgraded: ~p~n", [Upgraded]),

    {Added, Removed, Upgraded}.

upgraded_app(AppName, OldAppVer, NewAppVer) when OldAppVer /= NewAppVer ->
    {AppName, {OldAppVer, NewAppVer}};
upgraded_app(_, _, _) ->
    false.

app_list_diff(List1, List2) ->
    List3 = lists:umerge(lists:sort(proplists:get_keys(List1)),
                         lists:sort(proplists:get_keys(List2))),
    List3 -- proplists:get_keys(List2).

file_to_name(File) ->
    filename:rootname(filename:basename(File)).

gen_appup_which_apps(UpgradedApps, [First|Rest]) ->
    List = proplists:delete(list_to_atom(First), UpgradedApps),
    gen_appup_which_apps(List, Rest);
gen_appup_which_apps(Apps, []) ->
    Apps.

generate_appup_files(TargetDir,
                     NewVerPath, OldVerPath,
                     ModDeps, [{_App, {undefined, _}}|Rest],
                     State) ->
    generate_appup_files(TargetDir, NewVerPath, OldVerPath, ModDeps, Rest, State);
generate_appup_files(TargetDir,
                     NewVerPath, OldVerPath,
                     ModDeps, [{App, {OldVer, NewVer}}|Rest],
                     State) ->
    CurrentBaseDir = rebar_dir:base_dir(State),
    AppEbinDir = filename:join([CurrentBaseDir, "lib",
                                atom_to_list(App), "ebin"]),
    OldRelEbinDir = filename:join([OldVerPath, "lib",
                                atom_to_list(App) ++ "-" ++ OldVer, "ebin"]),
    NewRelEbinDir = filename:join([NewVerPath, "lib",
                                atom_to_list(App) ++ "-" ++ NewVer, "ebin"]),

    {AddedFiles, DeletedFiles, ChangedFiles} = beam_lib:cmp_dirs(NewRelEbinDir,
                                                                 OldRelEbinDir),

    ChangedNames = [list_to_atom(file_to_name(F)) || {F, _} <- ChangedFiles],
    ModDeps1 = [{N, [M1 || M1 <- M, lists:member(M1, ChangedNames)]}
                || {N, M} <- ModDeps],

    Added = [generate_instruction(added, File) || File <- AddedFiles],
    Deleted = [generate_instruction(deleted, File) || File <- DeletedFiles],
    Changed = [generate_instruction(changed, ModDeps1, File)
               || File <- ChangedFiles],

    Inst = lists:append([Added, Deleted, Changed]),

    AppUpFiles = case TargetDir of
                    undefined ->
                        RelAppup = filename:join([NewRelEbinDir,
                                                  atom_to_list(App) ++ ".appup"]),
                        EbinAppup = filename:join([AppEbinDir,
                                                   atom_to_list(App) ++ ".appup"]),
                        [RelAppup, EbinAppup];
                    _ ->
                        [filename:join([TargetDir, atom_to_list(App) ++ ".appup"])]
                 end,

    rebar_api:console("Generating appup for ~p in ~p~n",
        [App, AppUpFiles]),
    %% write each of the .appup files
    lists:foreach(fun(AppUpFile) ->
                    ok = file:write_file(AppUpFile,
                                         io_lib:fwrite(?APPUPFILEFORMAT,
                                                       [App, rebar3_appup_utils:now_str(),
                                                        NewVer, OldVer, Inst, OldVer])),
                    rebar_api:console("Generated appup for ~p in ~p~n",
                        [App, AppUpFile])
                  end, AppUpFiles),
    generate_appup_files(TargetDir, NewVerPath, OldVerPath, ModDeps, Rest, State);
generate_appup_files(_, _, _, _, [], _) -> ok.

generate_instruction(added, File) ->
    Name = list_to_atom(file_to_name(File)),
    {add_module, Name};
generate_instruction(deleted, File) ->
    Name = list_to_atom(file_to_name(File)),
    {delete_module, Name}.

generate_instruction(changed, ModDeps, {File, _}) ->
    {ok, {Name, List}} = beam_lib:chunks(File, [attributes, exports]),
    Behavior = get_behavior(List),
    CodeChange = is_code_change(List),
    Deps = proplists:get_value(Name, ModDeps, []),
    generate_instruction_advanced(Name, Behavior, CodeChange, Deps).

generate_instruction_advanced(Name, undefined, undefined, Deps) ->
    %% Not a behavior or code change, assume purely functional
    {load_module, Name, Deps};
generate_instruction_advanced(Name, [supervisor], _, _) ->
    %% Supervisor
    {update, Name, supervisor};
generate_instruction_advanced(Name, _, code_change, Deps) ->
    %% Includes code_change export
    {update, Name, {advanced, []}, Deps};
generate_instruction_advanced(Name, _, _, Deps) ->
    %% Anything else
    {load_module, Name, Deps}.

get_behavior(List) ->
    Attributes = proplists:get_value(attributes, List),
    case proplists:get_value(behavior, Attributes) of
        undefined -> proplists:get_value(behaviour, Attributes);
        Else -> Else
    end.

is_code_change(List) ->
    Exports = proplists:get_value(exports, List),
    case proplists:is_defined(code_change, Exports) orelse
        proplists:is_defined(system_code_change, Exports) of
        true ->
            code_change;
        false ->
            undefined
    end.

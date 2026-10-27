% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

% Same as couch_log_writer_stderr, but only error, critical, alert and
% emergency entries are written to stderr. Everything else is written to
% stdout, including structured reports (level `report`, e.g. mango-stats)
% and any level not listed here.

-module(couch_log_writer_stdout).
-behaviour(couch_log_writer).

-export([
    init/0,
    terminate/2,
    write/2
]).

-include("couch_log.hrl").

init() ->
    {ok, nil}.

terminate(_, _St) ->
    ok.

write(#log_entry{} = Entry, St) ->
    #log_entry{
        level = Level,
        pid = Pid,
        msg = Msg,
        msg_id = MsgId,
        time_stamp = TimeStamp
    } = couch_log_util:maybe_format_type(Entry),
    Fmt = "[~s] ~s ~s ~p ~s ",
    Args = [
        couch_log_util:level_to_string(Level),
        TimeStamp,
        config:node_name(),
        Pid,
        MsgId
    ],
    MsgSize = couch_log_config:get(max_message_size),
    Data = couch_log_trunc_io:format(Fmt, Args, MsgSize),
    write_line(device(Level), [Data, Msg, "\n"]),
    {ok, St}.

% Must be total: a crash here takes down couch_log_server.
device(Level) when
    Level =:= error;
    Level =:= err;
    Level =:= critical;
    Level =:= crit;
    Level =:= alert;
    Level =:= emergency;
    Level =:= emerg
->
    standard_error;
device(_) ->
    user.

% Never fail where couch_log_writer_stderr would not: if stdout cannot be
% written, fall back to stderr.
write_line(user, Line) ->
    try
        io:format(user, Line, [])
    catch
        _:_ ->
            io:format(standard_error, Line, [])
    end;
write_line(standard_error, Line) ->
    io:format(standard_error, Line, []).

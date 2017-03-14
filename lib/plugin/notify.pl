/*  Part of SWISH

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@cs.vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2017, VU University Amsterdam
			 CWI Amsterdam
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in
       the documentation and/or other materials provided with the
       distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/

:- module(swish_notify,
          [ follow/3,                           % +DocID, +ProfileID, +Options
            notify/2                            % +DocID, +Action
          ]).
:- use_module(library(settings)).
:- use_module(library(persistency)).
:- use_module(library(broadcast)).
:- use_module(library(lists)).
:- use_module(library(readutil)).
:- use_module(library(debug)).
:- use_module(library(apply)).
:- use_module(library(http/html_write)).
:- use_module(library(http/http_session)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/http_json)).

:- use_module(library(user_profile)).

:- use_module(email).
:- use_module('../bootstrap').
:- use_module('../storage').
:- use_module('../chat').

:- initialization
    start_mail_scheduler.

/** <module> SWISH notifications

This module keeps track of which users wish to track which notifications
and sending the notifications to the user.  If the target user is online
we will notify using an avatar.  Otherwise we send an email.

A user has the following options to control notifications:

  * Per (gitty) file
    - Notify update
    - Notify chat
  * By profile
    - Notify by E-mail: never/immediate/daily
*/

:- setting(database, callable, swish('data/notify.db'),
           "Database holding notifications").
:- setting(queue, callable, swish('data/notify-queue.db'),
           "File holding queued messages").
:- setting(daily, compound, 04:00,
           "Time at which to send daily messages").


		 /*******************************
		 *            DATABASE		*
		 *******************************/

:- persistent
        follower(docid:atom,
                 profile:atom,
                 options:list(oneof([update,chat]))).

notify_open_db :-
    db_attached(_),
    !.
notify_open_db :-
    setting(database, Spec),
    absolute_file_name(Spec, Path, [access(write)]),
    db_attach(Path, [sync(close)]).

%!  queue_event(+Profile, +DocID, +Action) is det.
%!  queue_event(+Profile, +DocID, +Action, +Status) is det.
%
%   Queue an email notification for  Profile,   described  by Action. We
%   simply append these events as Prolog terms to a file.

queue_event(Profile, DocID, Action) :-
    queue_event(Profile, DocID, Action, new).
queue_event(Profile, DocID, Action, Status) :-
    queue_file(Path),
    with_mutex(swish_notify,
               queue_event_sync(Path, Profile, DocID, Action, Status)).

queue_event_sync(Path, Profile, DocID, Action, Status) :-
    setup_call_cleanup(
        open(Path, append, Out, [encoding(utf8)]),
        format(Out, '~q.~n', [notify(Profile, DocID, Action, Status)]),
        close(Out)).

queue_file(Path) :-
    setting(queue, Spec),
    absolute_file_name(Spec, Path, [access(write)]).

%!  send_queued_mails is det.
%
%   Send possible queued emails.

send_queued_mails :-
    queue_file(Path),
    exists_file(Path), !,
    atom_concat(Path, '.sending', Tmp),
    with_mutex(swish_notify, rename_file(Path, Tmp)),
    read_file_to_terms(Tmp, Terms, [encoding(utf8)]),
    forall(member(Term, Terms),
           send_queued(Term)),
    delete_file(Tmp).
send_queued_mails.

send_queued(notify(Profile, DocID, Action, Status)) :-
    profile_property(Profile, email(Email)),
    profile_property(Profile, email_notifications(When)),
    When \== never, !,
    (   catch(send_notification_mail(Profile, DocID, Email, Action),
              Error, true)
    ->  (   var(Error)
        ->  true
        ;   update_status(Status, Error, NewStatus)
        ->  queue_event(Profile, Action, NewStatus)
        ;   true
        )
    ;   update_status(Status, failed, NewStatus)
    ->  queue_event(Profile, DocID, Action, NewStatus)
    ;   true
    ).

update_status(new, Status, retry(3, Status)).
update_status(retry(Count0, _), Status, retry(Count, Status)) :-
    Count0 > 0,
    Count is Count0 - 1.

%!  start_mail_scheduler
%
%   Start a thread that schedules queued mail handling.

start_mail_scheduler :-
    catch(thread_create(mail_main, _,
                        [ alias(mail_scheduler),
                          detached(true)
                        ]),
          error(permission_error(create, thread, mail_scheduler), _),
          true).

%!  mail_main
%
%   Infinite loop that schedules sending queued messages.

mail_main :-
    repeat,
    next_send_queue_time(T),
    get_time(Now),
    Sleep is T-Now,
    sleep(Sleep),
    thread_create(send_queued_mails, _,
                  [ detached(true),
                    alias(send_queued_mails)
                  ]),
    fail.

next_send_queue_time(T) :-
    get_time(Now),
    stamp_date_time(Now, date(Y,M,D0,H0,_M,_S,Off,TZ,DST), local),
    setting(daily, HH:MM),
    (   H0 @< HH
    ->  D = D0
    ;   D is D0+1
    ),
    date_time_stamp(date(Y,M,D,HH,MM,0,Off,TZ,DST), T).


%!  follow(+DocID, +ProfileID, +Flags) is det.
%
%   Assert that DocID is being followed by ProfileID using Flags.

follow(DocID, ProfileID, Flags) :-
    to_atom(DocID, DocIDA),
    to_atom(ProfileID, ProfileIDA),
    maplist(to_atom, Flags, Options),
    notify_open_db,
    (   follower(DocIDA, ProfileIDA, OldOptions)
    ->  (   OldOptions == Options
        ->  true
        ;   retractall_follower(DocIDA, ProfileIDA, _),
            (   Options \== []
            ->  assert_follower(DocIDA, ProfileIDA, Options)
            ;   true
            )
        )
    ;   Options \== []
    ->  assert_follower(DocIDA, ProfileIDA, Options)
    ;   true
    ).

nofollow(DocID, ProfileID, Flags) :-
    to_atom(DocID, DocIDA),
    to_atom(ProfileID, ProfileIDA),
    maplist(to_atom, Flags, Options),
    (   follower(DocIDA, ProfileIDA, OldOptions)
    ->  subtract(OldOptions, Options, NewOptions),
        follow(DocID, ProfileID, NewOptions)
    ;   true
    ).


%!  notify(+DocID, +Action) is det.
%
%   Action has been executed on DocID.  Notify all interested users.
%   Actions that may be notified:
%
%   - updated(Commit)
%     Gitty file was updated
%   - deleted(Commit)
%     Gitty file was deleted
%   - forked(OldCommit, Commit)
%     Gitty file was forked
%   - chat(Message)
%     A chat message was sent.  Message is the JSON content as a dict.
%     Message contains a `docid` key.

notify(DocID, Action) :-
    to_atom(DocID, DocIDA),
    notify_open_db,
    forall(follower(DocIDA, Profile, Options),
           notify_user(Profile, DocIDA, Action, Options)).

to_atom(Text, Atom) :-
    atom_string(Atom, Text).

%!  notify_user(+Profile, +DocID, +Action, +Options)
%
%   Notify the user belonging to Profile  about Action, which is related
%   to document DocID.

:- meta_predicate try(0).

notify_user(Profile, _, Action, _Options) :-	% exclude self
    event_generator(Action, Profile),
    debug(notify(self), 'Notification to self ~p', [Profile]),
    \+ debugging(notify_self),
    !.
notify_user(Profile, DocID, Action, Options) :-
    try(notify_online(Profile, Action, Options)),
    try(notify_by_mail(Profile, DocID, Action, Options)).

try(Goal) :-
    catch(Goal, Error, print_message(error, Error)),
    !.
try(Goal) :-
    print_message(error, goal_failed(Goal)).


		 /*******************************
		 *         BROADCAST API	*
		 *******************************/

:- unlisten(swish(_)),
   listen(swish(Event), notify_event(Event)).

% request to follow this file
notify_event(follow(DocID, ProfileID, Options)) :-
    follow(DocID, ProfileID, Options).
% events on gitty files
notify_event(updated(File, Commit)) :-
    atom_concat('gitty:', File, DocID),
    notify(DocID, updated(Commit)).
notify_event(deleted(File, Commit)) :-
    atom_concat('gitty:', File, DocID),
    notify(DocID, deleted(Commit)).
notify_event(created(_File, Commit)) :-
    storage_meta_data(Commit.get(previous), Meta),
    atom_concat('gitty:', Meta.name, DocID),
    notify(DocID, forked(Meta, Commit)).
% chat message
notify_event(chat(Message)) :-
    notify(Message.docid, chat(Message)).

%!  event_generator(+Event, -ProfileID) is semidet.
%
%   True when ProfileID refers to the user that initiated Event.

event_generator(updated(Commit),   Commit.get(profile_id)).
event_generator(deleted(Commit),   Commit.get(profile_id)).
event_generator(forked(_, Commit), Commit.get(profile_id)).


		 /*******************************
		 *     NOTIFY PEOPLE ONLINE	*
		 *******************************/

notify_online(ProfileID, Action, _Options) :-
    chat_to_profile(ProfileID, \short_notice(Action)).

short_notice(updated(Commit)) -->
    html([\committer(Commit), ' updated ', \file_name(Commit)]).
short_notice(deleted(Commit)) -->
    html([\committer(Commit), ' deleted ', \file_name(Commit)]).
short_notice(forked(OldCommit, Commit)) -->
    html([\committer(Commit), ' forked ', \file_name(OldCommit),
          ' into ', \file_name(Commit)
         ]).
short_notice(chat(Message)) -->
    html([\chat_user(Message), " chatted about ", \chat_file(Message)]).


		 /*******************************
		 *            EMAIL		*
		 *******************************/

% ! notify_by_mail(+Profile, +DocID, +Action, +FollowOptions) is semidet.
%
%   Send a notification by mail. Optionally  schedules the message to be
%   send later.
%
%   @tbd: if sending fails, should we queue the message?

notify_by_mail(Profile, DocID, Action, Options) :-
    profile_property(Profile, email(Email)),
    profile_property(Profile, email_notifications(When)),
    When \== never,
    must_notify(Action, Options),
    (   When == immediate
    ->  debug(notify(email), 'Sending notification mail to ~p', [Profile]),
        send_notification_mail(Profile, DocID, Email, Action)
    ;   debug(notify(email), 'Queing notification mail to ~p', [Profile]),
        queue_event(Profile, DocID, Action)
    ).

must_notify(chat(_), Options) :- !,
    memberchk(chat, Options).
must_notify(_, Options) :-
    memberchk(update, Options).

% ! send_notification_mail(+Profile, +DocID, +Email, +Action) is semidet.
%
%   Actually send a notification mail.  Fails   if  Profile  has no mail
%   address or does not want to be notified by email.

send_notification_mail(Profile, DocID, Email, Action) :-
    phrase(subject(Action), Codes),
    string_codes(Subject, Codes),
    smtp_send_html(Email, \mail_message(Profile, DocID, Action),
                   [ subject(Subject)
                   ]).

subject(Action) -->
    subject_action(Action).

subject_action(updated(Commit)) -->
    txt_commit_file(Commit), " updated by ", txt_committer(Commit).
subject_action(deleted(Commit)) -->
    txt_commit_file(Commit), " deleted by ", txt_committer(Commit).
subject_action(forked(_, Commit)) -->
    txt_commit_file(Commit), " forked by ", txt_committer(Commit).
subject_action(chat(Message)) -->
    txt_chat_user(Message), " chatted about ", txt_chat_file(Message).


		 /*******************************
		 *             STYLE		*
		 *******************************/

style -->
    email_style,
    notify_style.

notify_style -->
    html({|html||
<style>
 .block            {margin-left: 2em;}
p.commit-message,
p.chat             {color: darkgreen;}
p.nocommit-message {color: orange;}
pre.query          {}
div.query	   {margin-top:2em; border-top: 1px solid #888;}
div.query-title	   {font-size: 80%; color: #888;}
div.nofollow	   {margin-top:2em; border-top: 1px solid #888;
                    font-size: 80%; color: #888; }
</style>
         |}).




		 /*******************************
		 *            HTML BODY		*
		 *******************************/

%!  message(+ProfileID, +DocID, +Action)//

mail_message(ProfileID, DocID, Action) -->
    dear(ProfileID),
    notification(Action),
    unsubscribe_options(ProfileID, DocID, Action),
    signature,
    style.

notification(updated(Commit)) -->
    html(p(['The file ', \file_name(Commit),
            ' has been updated by ', \committer(Commit), '.'])),
    commit_message(Commit).
notification(forked(OldCommit, Commit)) -->
    html(p(['The file ', \file_name(OldCommit),
            ' has been forked into ', \file_name(Commit), ' by ', \committer(Commit), '.'])),
    commit_message(Commit).
notification(deleted(Commit)) -->
    html(p(['The file ', \file_name(Commit),
            ' has been deleted by ', \committer(Commit), '.'])),
    commit_message(Commit).
notification(chat(Message)) -->
    html(p([\chat_user(Message), " chatted about ", \chat_file(Message)])),
    chat_message(Message).

file_name(Commit) -->
    { public_url(web_storage, path_postfix(Commit.name), HREF, []) },
    html(a(href(HREF), Commit.name)).

committer(Commit) -->
    { ProfileID = Commit.get(profile_id) }, !,
    profile_name(ProfileID).
committer(Commit) -->
    html(Commit.get(owner)).

commit_message(Commit) -->
    { Message = Commit.get(commit_message) }, !,
    html(p(class(['commit-message', block]), Message)).
commit_message(_Commit) -->
    html(p(class(['no-commit-message', block]), 'No message')).

chat_file(Message) -->
    { string_concat("gitty:", File, Message.docid),
      public_url(web_storage, path_postfix(File), HREF, [])
    },
    html(a(href(HREF), File)).

chat_user(Message) -->
    { User = Message.get(user).get(name) },
    !,
    html(User).
chat_user(_Message) -->
    html("Someone").

chat_message(Message) -->
    (chat_text(Message)                  -> [] ; []),
    (chat_payloads(Message.get(payload)) -> [] ; []).

chat_text(Message) -->
    html(p(class([chat,block]), Message.get(text))).

chat_payloads([]) --> [].
chat_payloads([H|T]) --> chat_payload(H), chat_payloads(T).

chat_payload(PayLoad) -->
    { atom_string(Type, PayLoad.get(type)) },
    chat_payload(Type, PayLoad),
    !.
chat_payload(_) --> [].

chat_payload(query, PayLoad) -->
    html(div(class(query),
             [ div(class('query-title'), 'Query'),
               pre(class([query, block]), PayLoad.get(query))
             ])).
chat_payload(Type, _) -->
    html(p(['Unknown payload of type ~q'-[Type]])).


		 /*******************************
		 *          UNSUBSCRIBE		*
		 *******************************/

unsubscribe_options(ProfileID, DocID, _) -->
    html(div(class(nofollow),
             [ 'Stop following ',
               \nofollow_link(ProfileID, DocID, [chat]), '||',
               \nofollow_link(ProfileID, DocID, [update]), '||',
               \nofollow_link(ProfileID, DocID, [chat,update]),
               ' about this document'
             ])).

nofollow_link(ProfileID, DocID, What) -->
    email_action_link(\nofollow_link_label(What),
                      nofollow_page(ProfileID, DocID, What),
                      nofollow(ProfileID, DocID, What),
                      []).

nofollow_link_label([chat])         --> html(chats).
nofollow_link_label([update])       --> html(updates).
nofollow_link_label([chat, update]) --> html('all notifications').

nofollow_done([chat])         --> html(chat).
nofollow_done([update])       --> html(update).
nofollow_done([chat, update]) --> html('any notifications').

nofollow_page(ProfileID, DocID, What, _Request) :-
    reply_html_page(
        email_confirmation,
        title('SWISH -- Stopped following'),
        [ \email_style,
          \dear(ProfileID),
          p(['You will no longer receive ', \nofollow_done(What),
             'notifications about ', \docid_link(DocID), '. ',
             'You can reactivate following this document using the \c
              File/Follow ... menu in SWISH.  You can specify whether \c
              and when you like to receive email notifications from your \c
              profile page.'
            ]),
          \signature
        ]).

docid_link(DocID) -->
    { atom_concat('gitty:', File, DocID),
      http_link_to_id(web_storage, path_postfix(File), HREF)
    },
    !,
    html(a(href(HREF), File)).
docid_link(DocID) -->
    html(DocID).


		 /*******************************
		 *  TEXT RULES ON GITTY COMMITS	*
		 *******************************/

txt_commit_file(Commit) -->
    write(Commit.name).

txt_committer(Commit) -->
    { ProfileID = Commit.get(profile_id) }, !,
    txt_profile_name(ProfileID).
txt_committer(Commit) -->
    write(Commit.get(owner)), !.



		 /*******************************
		 *    RULES ON GITTY COMMITS	*
		 *******************************/

txt_profile_name(ProfileID) -->
    { profile_property(ProfileID, name(Name)) },
    write(Name).


		 /*******************************
		 *    RULES ON CHAT MESSAGES	*
		 *******************************/

txt_chat_user(Message) -->
    { User = Message.get(user).get(name) },
    !,
    write(User).
txt_chat_user(_Message) -->
    "Someone".

txt_chat_file(Message) -->
    { string_concat("gitty:", File, Message.docid) },
    !,
    write(File).


		 /*******************************
		 *            BASICS		*
		 *******************************/

write(Term, Head, Tail) :-
    format(codes(Head, Tail), '~w', [Term]).


		 /*******************************
		 *        HTTP HANDLING		*
		 *******************************/

:- http_handler(swish(follow/options), follow_file_options,
                [ id(follow_file_options) ]).
:- http_handler(swish(follow/save), save_follow_file,
                [ id(save_follow_file) ]).

%!  follow_file_options(+Request)
%
%   Edit the file following options for the current user.

follow_file_options(Request) :-
    http_parameters(Request,
                    [ docid(DocID, [atom])
                    ]),
    http_in_session(_SessionID),
    http_session_data(profile_id(ProfileID)), !,
    profile_property(ProfileID, email_notifications(When)),

    (   follower(DocID, ProfileID, Follow)
    ->  true
    ;   Follow = []
    ),

    follow_file_widgets(DocID, When, Follow, Widgets),

    reply_html_page(
        title('Follow file options'),
        \bt_form(Widgets,
                 [ class('form-horizontal'),
                   label_columns(sm-3)
                 ])).
follow_file_options(_Request) :-
    reply_html_page(
        title('Follow file options'),
        [ p('You must be logged in to follow a file'),
          \bt_form([ button_group(
                         [ button(cancel, button,
                                  [ type(danger),
                                    data([dismiss(modal)])
                                  ])
                         ], [])
                   ],
                   [ class('form-horizontal'),
                     label_columns(sm-3)
                   ])
        ]).

:- multifile
    user_profile:attribute/3.

follow_file_widgets(DocID, When, Follow,
    [ hidden(docid, DocID),
      checkboxes(follow, [update,chat], [value(Follow)]),
      select(email_notifications, NotificationOptions, [value(When)])
    | Buttons
    ]) :-
    user_profile:attribute(email_notifications, oneof(NotificationOptions), _),
    buttons(Buttons).

buttons(
    [ button_group(
          [ button(save, submit,
                   [ type(primary),
                     data([action(SaveHREF)])
                   ]),
            button(cancel, button,
                   [ type(danger),
                     data([dismiss(modal)])
                   ])
          ],
          [
          ])
    ]) :-
    http_link_to_id(save_follow_file, [], SaveHREF).

%!  save_follow_file(+Request)
%
%   Save the follow file options

save_follow_file(Request) :-
    http_read_json_dict(Request, Dict),
    debug(profile(update), 'Got ~p', [Dict]),
    http_in_session(_SessionID),
    http_session_data(profile_id(ProfileID)),
    debug(notify(options), 'Set follow options to ~p', [Dict]),
    set_profile(ProfileID, email_notifications=Dict.get(email_notifications)),
    follow(Dict.get(docid), ProfileID, Dict.get(follow)),
    reply_json_dict(_{status:success}).

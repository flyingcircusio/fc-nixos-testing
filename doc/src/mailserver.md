(nixos-mailserver)=

# Mail server

The role `mailserver` installs a complete mail server for incoming and outgoing mail.
Incoming mail is either delivered to IMAP mailboxes via dovecot, or forwarded to
an application via alias/transport configs. Outgoing mail is accepted on the
submission port or via a *sendmail* executable.

An optional web mail UI is included. This role also includes state-of-the-art
spam control.

User accounts can be created/modified dynamically. There is, however, no default
mechanism for user management besides text files.

## Which components are included?

The main ingredients of this role are [Postfix] for mail delivery, [Dovecot] as
IMAP access server, and [Roundcube] as web frontend.
{ref}`nixos-postgresql-server` is used as a database to store Roundcube settings.

We rely mainly on [Rspamd] for spam protection. To get outgoing mails
delivered, they are signed with[OpenDKIM] and a basic [SPF] and [SRS] setup
is included.

Additionally, a Thunderbird-compatible client [autoconfiguration] XML file is
provided which helps many clients to configure themselves properly.

(nixos-mailserver-basic-setup)=

## How do I perform a basic setup?

:::{warning}
We strongly recommend putting the `mailserver` role on a separate
VM without other roles (`postgresql` being the only exception). The role
has many moving parts which could interfere with roles and applications.
:::

First, you need a public IPv4 and IPv6 address for your mail server's frontend
interface. Contact our [support](/platform/index.html#support) if you don't
have any.
Then, pick a host to serve mails from. This host will be advertised via the MX
record on your domain. You could for example choose `mail.example.com` to handle mail
for `example.com`.
The host (called **mailHost** from here on) of your choosing must resolve to the
FE addresses for both forward and reverse lookups (A and AAAA records).

Additionally, some mail providers (namely [Telekom/T-Online](https://postmaster.t-online.de/#t4.1))
may require that your mailserver has an imprint served at its hostname.

For this you can either set `imprintUrl` to the location of your existing
imprint, or use `imprintText` to specify an imprint in HTML format.

:::{warning}
Specifying `imprintUrl` without a protocol scheme is still supported, but
deprecated and will give a warning on evaluation.
:::

Note that it is not possible to set both `imprintUrl` and `imprintText` at the
same time and imprint cannot be used if you serve webmail under the
`mailHost` (meaning `mailHost` and `webmailHost` cannot be the same).

:::{warning}
Incorrect DNS setup is the most frequent source of delivery problems. Let our
[support](/platform/index.html#support) check your setup if in doubt.
:::

If you choose to use the Roundcube webmail UI by adding the `webmailHost`
setting like in the example, make sure to enable a `postgresql` role on the
machine because Roundcube needs it to store its settings. We recommend you
use the newest version that is available at the moment.

Create a configuration file like {file}`/etc/local/nixos/mail-config.nix` which
contains all the basic pieces. In the following example, the server's `mailHost`
is *mail.test.fcio.net* and it serves as MX for the mail domains *test.fcio.net*
and *test2.fcio.net*:

```nix
{
  flyingcircus.roles.mailserver = {
    mailHost = "mail.test.fcio.net";
    webmailHost = "webmail.test.fcio.net";
    domains = {
      "test.fcio.net".primary = true;
      "test2.fcio.net".autoconfig = false;
    };
    imprintUrl = "https://your-company.tld/imprint";
  };
}
```

:::{note}
There must always be exactly one domain with the primary option set.
:::

This sets up [autoconfiguration] for mail clients that wish to use *test.fcio.net*.
Autoconfiguration is disabled for *test2.fcio.net* in the example.

Run {command}`sudo fc-manage switch` to have everything configured on the system.

After running the above command, a newly-generated file {file}`/etc/local/mail/dns.zone`
will contain all necessary DNS records for your mail server.
Insert the records contained within the file into the appropriate DNS zones and
don't forget to check PTR records for reverse DNS lookups.

## How do I create users?

Users can be added in either of two ways:

### 1. via Nix

Users can be added in your NixOS configuration using the key `mailserver.loginAccounts`.
The value is an attribute set that represents your users, for example

```nix
{
  mailserver.loginAccounts = {
    "user1@test.fcio.net" = {
      quota = "4G";
      sendOnly = true;
      aliases = ["noreply@test.fcio.net"];
      hashedPassword = "$y$j9T$whHoksmVCZ1rjW2htMznw/$4WzPhNQAe8VcVllG7jC7kFGZMIy/TiIGSULMp3vzAL7";
    };
    "user2@test.fcio.net" = {
      quota = "10G";
      hashedPassword = "$y$j9T$whHoksmVCZ1rjW2htMznw/$4WzPhNQAe8VcVllG7jC7kFGZMIy/TiIGSULMp3vzAL7";
    };
  };
}
```

### 2. via /etc/local/mail/users.json

Edit the file {file}`/etc/local/mail/users.json` to add user accounts. Example:

```json
{
  "user1@test.fcio.net": {
    "aliases": ["first.last@test.fcio.net"],
    "hashedPassword": "$y$j9T$whHoksmVCZ1rjW2htMznw/$4WzPhNQAe8VcVllG7jC7kFGZMIy/TiIGSULMp3vzAL7",
    "quota": "4G",
    "sieveScript": null
  }
}
```

This file contains of key/value pairs where the key is the main email address
and the value is an attribute set of configuration options.
The domain parts of all e-mail addresses must be listed in the `domains` option
in the corresponding configuration file, e.g. {file}`/etc/local/nixos/mail-config.nix`
and the password must be hashed via {command}`mkpasswd -m yescrypt {PASSWORD}`.


## How do mail users log into the mail server?

- Username: full e-mail address
- Incoming: IMAP with STARTTLS, mailHost port 143
- Outgoing: SMTP with STARTTLS, mailHost port 587.

If the *webmailHost* option is defined, users can log into the web frontend with
their full e-mail address and password.

## How to change passwords

We support two scenarios: static passwords and dynamic passwords.

### Static passwords

Passwords are set by the administrator and put into {file}`users.json`. They cannot be
changed by users.

### Dynamic passwords

To enable users to change their password themselves, leave the
**hashedPassword** option in {file}`/etc/local/mail/users.json` empty and set
the initial password in {file}`/var/lib/dovecot/passwd` instead. This file
consists of an e-mail address/password pair per user. Example:

```
user1@test.fcio.net:$y$j9T$whHoksmVCZ1rjW2htMznw/$4WzPhNQAe8VcVllG7jC7kFGZMIy/TiIGSULMp3vzAL7
```

The initial password hash can be created with {command}`mkpasswd -m yescrypt
{PASSWORD}`, as shown above. Afterwards, user can log into the Roundcube web mail
frontend and change their password in the settings menu.

## The spam filter misclassifies mails. What to do?

`Rspamd` has a good set of defaults but is not perfect. To get be results, it must
receive training.

False positive (ham classified as spam)

: Move that e-mail message from the `Junk` folder back into the `INBOX` folder.

False negative (spam classified as ham)

: Move that e-mail message from the `INBOX` folder into the `Junk` folder.

In both cases, the spam filter's statistics module will be automatically
trained. Note that the spam filter needs a certain amount of training material
to become effective. This means that training effects will show up after time
and not immediately.

(mail-into-backends)=

## How do I forward mails to remote addresses?

Declare a [virtual alias] map and create remote aliases there. Add the
following snippet to your NixOS configuration, for example in the
file {file}`/etc/local/nixos/mail-config.nix`:

```
flyingcircus.roles.mailserver.dynamicMaps.virtual_alias_maps = ["/etc/local/mail/virtual_aliases"];
```

Then, create the file {file}`/etc/local/mail/virtual_aliases` and define your aliases.
Example contents:

```
alias@test.fcio.net remote@address
```

Invoke {command}`sudo systemctl reload postfix` to recompile the maps after the map
contents has been changed. Invoke {command}`sudo fc-manage switch` as usual if
the content of the NixOS module {file}`/etc/local/nixos/mail-config.nix` have been changed.

## How do I feed mails into an application?

Feeding mails destined to special accounts into backend application servers can
be done with a [transport] map. Transport and other Postfix lookup tables are
declared inside a `dynamicMaps` key in `mail-config.nix`. The application should open a
port capable of speaking SMTP on its srv interface. Example:

```
flyingcircus.roles.mailserver.dynamicMaps.transport_maps = [ "/etc/local/mail/transport" ];
```

Example transport file contents:

```
specialaddress@test.fcio.net relay:172.30.40.50:8025
```

In case a whole subdomain should be piped into an application server, we need
both a transport and a [relay_domains] map. Both map declarations may point to
the same source as *relay_domains* uses only the first field of each line.

Example config snippet:

```nix
{
  flyingcircus.roles.mailserver.dynamicMaps = {
    transport_maps = [ "/etc/local/mail/transport" ];
    relay_domains = [ "/etc/local/mail/transport" ];
  };
}
```

Example transport file contents:

```
subdomain.test.fcio.net relay:172.30.40.50:8025
```

An DNS MX record for that subdomain must be present as well.

Invoke {command}`sudo systemctl reload postfix` to recompile maps after map
contents has been changed. Invoke {command}`sudo fc-manage switch` as usual if
the contents of `mail-config.nix` have been changed.

## Reference

### DNS Glossary

Some important terminology for understanding DNS issues:

HELO name

: The canonical name of the mail server. The HELO name is the same as the value
  of the **mailHost** option and the **myhostname** Postfix configuration
  variable. The HELO name must be listed in the **MX** records of
  all served *mail domains*.

  Example: mail.test.fcio.net

Frontend IP addresses

: Public IPv4 and/or IPv6 adresses. **A** and **AAAA** queries of the HELO name
  must resolve to the frontend IP addresses. Each address must have a **PTR**
  record which must resolve exactly to the HELO name.

  Example: 195.62.126.119, 2a02:248:101:62::1191

Mail domain

: List of DNS domains that serve as domain part in mail addresses hosted by a
  mail server. Not to be confused with the domain part of the server's FQDN
  which may be the same or may not.  Each *domain* must have a **MX** record
  which points to the mail server's *HELO name*.

  Example: test.fcio.net, test2.fcio.net

### Role options

All options can be set in {file}`/etc/local/mail/config.json`
or in {ref}`Nix config <nixos-custom-modules>` with the prefix *flyingcircus.roles.mailserver*.

Frequently used options:

domains (attribute set (object) or list)

: *mail domains* which should be served by this mail server.
  Keys of the set are the domains, values are options for a specific domain.
  You can find these options below. See {ref}`nixos-mailserver-basic-setup`
  for a working example.

  The option still supports a list of strings instead of a attribute set (object).
  Using a list is deprecated and should be migrated to the attribute set form.

domains.\<domain>.enable (boolean, default true)

: Enable or disable a domain.

domains.\<domain>.autoconfig (boolean, default true)

: [Autoconfiguration] for mail clients is enabled by default.
  A DNS entry must exist for *autoconfig.\<domain>*.
  Sets up a SSL certificate automatically using Let's Encrypt.

domains.\<domain>.primary (boolean)

: Make this the primary domain for internal services (bounce emails, etc).

mailHost

: *HELO name*, see above.

webmailHost

: Virtual server name for the Roundcube web mail service. Appropriate DNS
  entries are expected to point to the VM's frontend address. If this option is
  set, the Roundcube service will be enabled. Make sure that a `postgresql`
  role is enabled when adding this option.

rootAlias

: E-mail address to receive all mails to the local root account.

dynamicMaps

: Hash map of Postfix maps (like [transport]) and one or more file paths
  containing map records. See section {ref}`mail-into-backends` for details.

Specialist options:

redisDatabase

: Database number (0-15) for Rspamd. Defaults to 5. The database number can
  be adjusted if any another local application happens to use DB 5.

smtpBind4 and smtpBind6

: Which frontend address to use in case ethfe has several of them.

explicitSmtpBind

: Whether to include explicit smtp_bind_address in the Postfix main.cf file.
  Defaults to true if ethfe has more than one IPv4 or IPv6 address. Needs
  to be overridden only in very special cases.

passwdFile

: Virtual mail users listing in {manpage}`passwd(7)` format. Set this if an
  application generates this file automatically and puts it into an
  application-specific location.

### User options

Keys that can be set per user in {file}`/etc/local/mail/users.json`.

aliases

: List of alternative e-mail addresses that will be delivered into this
  mailbox. Note that domain parts of all aliases must be listed in the *domains*
  option.

catchAll

: List of subdomains for which all incoming mails, regardless of their local
  parts, will be delivered into this mailbox. All subdomains must be listed in
  the *domains* option.

hashedPassword

: Either a salted SHA-256 password hash (for static passwords) or empty string.
  In the latter case, the password is read from {file}`/var/lib/dovecot/passwd`.

quota

: Mailbox space limit like "512M" or "2G".

sieveScript

: Mail processing rules in the [Sieve] language. Users can set dynamic sieve
  scripts from the Roundcube web UI if left empty.

### Further configuration files

/etc/local/mail/local_valiases.json

: Additional aliases which are not mentioned in users.json. Expected to be a
  dict with the alias as key and the receiving address as value.

/etc/local/mail/main.cf

: Additional Postfix {manpage}`postconf(5)` settings.

/etc/local/mail/dns.zone

: Copy-and-paste DNS records for inclusion in zone files. Adapt if necessary.

### Monitoring

Monitoring checks/metrics created by this role:

- Port checks for SMTP, submission, IMAP, and IMAPs.
- Postfix excessive queue length check.
- Postfix queue length, size, and age metrics.

% vim: set spell spelllang=en:

[autoconfiguration]: https://wiki.mozilla.org/Thunderbird:Autoconfiguration
[dovecot]: https://dovecot.org/
[opendkim]: http://www.opendkim.org/
[postfix]: http://www.postfix.org/
[relay_domains]: http://www.postfix.org/postconf.5.html#relay_domains
[roundcube]: https://roundcube.net/
[rspamd]: https://rspamd.com/
[sieve]: https://en.wikipedia.org/wiki/Sieve_(mail_filtering_language)
[spf]: https://en.wikipedia.org/wiki/Sender_Policy_Framework
[srs]: https://github.com/roehling/postsrsd
[transport]: http://www.postfix.org/transport.5.html
[virtual alias]: http://www.postfix.org/postconf.5.html#virtual_alias_maps

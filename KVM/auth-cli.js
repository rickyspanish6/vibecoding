#!/usr/bin/env node
// Account recovery from the command line. Whoever can run this on the server can reset any account, which is the point:
// it is the way back in when a password is lost. Needs no running server, and a running one picks the change up.
//
//   node auth-cli.js list
//   node auth-cli.js reset <username>          new random password (shown once), must be changed at next login
//   node auth-cli.js create-admin <username>   create an administrator, or make an existing user one and reset it
import { listUsers, recoverUser, audit } from './auth.js';

const [, , command, username] = process.argv;
const usage = () => {
  console.error('Usage:\n  node auth-cli.js list\n  node auth-cli.js reset <username>\n  node auth-cli.js create-admin <username>');
  process.exit(2);
};

try {
  if (command === 'list') {
    const users = listUsers();
    if (!users.length) console.log('No users yet: open the dashboard on this machine to create the first administrator.');
    for (const u of users) console.log(`${u.username.padEnd(20)} ${u.roleLabel.padEnd(14)} ${u.disabled ? 'disabled' : 'active'}${u.mustChange ? ' (must change password)' : ''}`);
  } else if ((command === 'reset' || command === 'create-admin') && username) {
    const { created, password } = recoverUser(username, { admin: command === 'create-admin' });
    audit({ event: 'cli-recovery', user: username, action: command, created });
    console.log(`${created ? 'Created administrator' : 'Reset'} "${username}".`);
    console.log(`Temporary password (shown once): ${password}`);
    console.log('It must be changed at the next sign-in. Any open sessions for this account are signed out.');
  } else usage();
} catch (e) {
  console.error(e.message);
  process.exit(1);
}

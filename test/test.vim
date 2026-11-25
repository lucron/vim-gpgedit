vim9script
# Run by run.sh, which sets up $DIR and the keyring.
const dir = $DIR

def Sys(cmd: string): list<string>
  return systemlist(cmd)
enddef
def Open(name: string)
  execute 'silent edit! ' .. fnameescape(dir .. '/' .. name)
enddef
# Bypasses the wrapper, because Sys() itself puts the output in a temporary file
def Plain(name: string): list<string>
  return Sys('"$GPG" --batch -qd ' .. shellescape(dir .. '/' .. name) .. ' 2>/dev/null')
enddef
def Recipients(name: string): list<string>
  var out: list<string> = []
  for l in Sys('gpg --batch --list-packets --list-only ' .. shellescape(dir .. '/' .. name) .. ' 2>/dev/null')
    const id = matchstr(l, '^:pubkey enc packet.* keyid \zs\x\+')
    if id != ''
      const uid = Sys('gpg --batch --with-colons --list-keys ' .. id)->filter((_, x) => x =~ '^uid')[0]
      add(out, split(uid, ':', 1)[9])
    endif
  endfor
  return sort(out)
enddef
# Run a command and return what it says, also for errors
def Say(cmd: string): string
  return execute(cmd, 'silent!')
enddef
def Bytes(name: string): string
  return string(readblob(dir .. '/' .. name))
enddef

def Test_roundtrip()
  const orig = readfile(dir .. '/plain')
  Open('ok file.gpg')
  assert_equal(orig, getline(1, '$'))
  assert_false(&modified)
  assert_false(&swapfile)
  assert_false(&undofile)
  assert_equal('', &viminfo)
  append('$', 'line-new')
  silent write
  assert_false(&modified)
  assert_equal(orig + ['line-new'], Plain('ok file.gpg'))
  assert_equal(['Alice Own <alice@example.test>', 'Bob Test <bob@example.test>'], Recipients('ok file.gpg'))
  assert_equal('rw-r-----', getfperm(dir .. '/ok file.gpg'))
  # a second save of the same buffer must not look like a foreign change
  append('$', 'line-2')
  silent write
  assert_equal(orig + ['line-new', 'line-2'], Plain('ok file.gpg'))
enddef

def Test_undo_does_not_clear_buffer()
  Open('ok file.gpg')
  silent! undo
  assert_true(line('$') > 1)
enddef

def Test_armor_is_kept()
  Open('armor.gpg')
  append('$', 'x')
  silent write
  assert_equal('-----BEGIN PGP MESSAGE-----', readfile(dir .. '/armor.gpg')[0])
enddef

def Test_foreign_change()
  Open('armor.gpg')
  append('$', 'mine')
  Sys('cp ' .. shellescape(dir .. '/hidden.gpg') .. ' ' .. shellescape(dir .. '/armor.gpg'))
  const before = Bytes('armor.gpg')
  assert_match('changed by someone else', Say('write'))
  assert_equal(before, Bytes('armor.gpg'))
  assert_true(&modified)
  silent write!
  assert_notequal(before, Bytes('armor.gpg'))
  assert_false(&modified)
enddef

def Test_other_target()
  Open('ok file.gpg')
  const before = Bytes('signed.gpg')
  execute 'silent! write ' .. dir .. '/signed.gpg'
  assert_equal(before, Bytes('signed.gpg'))
  execute 'silent write ' .. dir .. '/copy.gpg'
  assert_equal(getline(1, '$'), Plain('copy.gpg'))
enddef

def Test_not_decryptable()
  const before = Bytes('foreign.gpg')
  assert_match('decryption failed', Say('edit! ' .. dir .. '/foreign.gpg'))
  assert_false(&modifiable)
  silent! write!
  assert_equal(before, Bytes('foreign.gpg'))
enddef

def Test_unknown_signer()
  Open('signed.gpg')
  assert_equal(readfile(dir .. '/plain'), getline(1, '$'))
enddef

def Test_hidden_recipient()
  Open('hidden.gpg')
  assert_true(&readonly)
  const before = Bytes('hidden.gpg')
  silent! write!
  assert_equal(before, Bytes('hidden.gpg'))
enddef

def Test_range_write()
  Open('ok file.gpg')
  assert_fails(':1,2write! ' .. dir .. '/part.gpg', 'only whole buffers')
  assert_false(filereadable(dir .. '/part.gpg'))
enddef

def Test_revoked()
  Open('revoked.gpg')
  const before = Bytes('revoked.gpg')
  append('$', 'x')
  assert_match('Unusable public key', Say('write'))
  assert_equal(before, Bytes('revoked.gpg'))
  GpgList
  assert_match('\[REVOKED\]$', getline(3))
  assert_match('not applied: REVOKED', Say('write'))
  setline(3, 'carol')
  silent write
  quit
  silent write
  assert_equal(['Alice Own <alice@example.test>', 'Carol New <carol@example.test>'], Recipients('revoked.gpg'))
  assert_equal('x', Plain('revoked.gpg')[-1])
enddef

def Test_list_errors()
  Open('ok file.gpg')
  GpgList
  append('$', 'nobody')
  assert_match('no key found for "nobody"', Say('write'))
  setline('$', 'dora')
  assert_match('ambiguous', Say('write'))
  assert_match('^? \x\{16}  Dora', getline('$'))
  assert_match('pick a key', Say('write'))
  silent :%delete _
  assert_match('list is empty', Say('write'))
  setline(1, 'bob')
  assert_match('your own key is missing', Say('write'))
  quit!
  assert_equal(2, len(b:gpg_recipients))
  assert_false(&modified)
enddef

def Test_list_own_key_override()
  Open('copy.gpg')
  GpgList
  silent :%delete _
  setline(1, 'bob')
  silent write!
  quit
  silent write
  assert_equal(['Bob Test <bob@example.test>'], Recipients('copy.gpg'))
enddef

def Test_new_file()
  Open('new.gpg')
  setline(1, 'hello')
  assert_match('no recipients', Say('write'))
  assert_false(filereadable(dir .. '/new.gpg'))
  GpgList
  append('$', 'alice')
  silent write
  quit
  silent write
  assert_equal(['hello'], Plain('new.gpg'))
enddef

def Test_no_leftovers()
  assert_equal('', glob(dir .. '/.*~'))
  # recorded by the gpg wrapper in run.sh
  assert_equal([], filereadable(dir .. '/leaks') ? readfile(dir .. '/leaks') : ['leak check did not run'])
  assert_equal([], Sys('grep -rlE "line1|line-new" ' .. shellescape(dir .. '/tmp') .. ' ' .. shellescape(dir .. '/viminfo') .. ' 2>/dev/null'))
enddef

const tests =<< trim END
  roundtrip undo_does_not_clear_buffer armor_is_kept foreign_change other_target
  not_decryptable unknown_signer hidden_recipient range_write revoked
  list_errors list_own_key_override new_file no_leftovers
END
for name in split(join(tests))
  try
    execute 'Test_' .. name .. '()'
  catch
    add(v:errors, 'Test_' .. name .. ': ' .. v:exception .. ' ' .. v:throwpoint)
  endtry
  silent! only!
endfor
writefile(v:errors + ['done: ' .. len(split(join(tests))) .. ' tests, ' .. len(v:errors) .. ' failures'], dir .. '/result')
qall!

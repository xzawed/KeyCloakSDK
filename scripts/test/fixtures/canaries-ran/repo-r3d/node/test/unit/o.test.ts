const flaky = process.platform === 'win32'

it('o9 fails expression', { fails: flaky }, () => {})

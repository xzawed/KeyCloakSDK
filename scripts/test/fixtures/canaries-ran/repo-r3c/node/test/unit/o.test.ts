const base = { fails: true }

it('o8 options spread', { ...base, timeout: 5000 }, () => {})

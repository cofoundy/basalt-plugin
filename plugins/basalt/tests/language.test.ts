import { expect, test } from 'claude-code/testing'

import { pickLanguage } from '../hooks/register'

test('English unless the locale is Spanish, POSIX precedence', () => {
  expect(pickLanguage(undefined, undefined, undefined)).toBe('en')
  expect(pickLanguage(undefined, undefined, 'en_US.UTF-8')).toBe('en')
  expect(pickLanguage(undefined, undefined, 'es_PE.UTF-8')).toBe('es')
  expect(pickLanguage('', '', 'es_ES.UTF-8')).toBe('es')
  expect(pickLanguage(undefined, 'es_MX.UTF-8', 'en_US.UTF-8')).toBe('es')
  expect(pickLanguage('en_US.UTF-8', undefined, 'es_PE.UTF-8')).toBe('en')
  expect(pickLanguage('C', undefined, 'es_PE.UTF-8')).toBe('en')
})

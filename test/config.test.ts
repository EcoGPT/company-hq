import { describe, expect, test } from 'bun:test';
import { envNumber, envString, listenAddress, localUrl } from '../src/config';

describe('env', () => {
	test('a string falls back when unset or blank, and is trimmed otherwise', () => {
		expect(envString({}, 'X', 'd')).toBe('d');
		expect(envString({ X: '  ' }, 'X', 'd')).toBe('d');
		expect(envString({ X: ' v ' }, 'X', 'd')).toBe('v');
	});

	test('a blank number falls back instead of reading as 0', () => {
		expect(envNumber({ PORT: '' }, 'PORT', 8787)).toBe(8787);
		expect(envNumber({ PORT: '  ' }, 'PORT', 8787)).toBe(8787);
	});

	test('a number falls back when unset or not a number', () => {
		expect(envNumber({}, 'PORT', 8787)).toBe(8787);
		expect(envNumber({ PORT: 'eighty' }, 'PORT', 8787)).toBe(8787);
		expect(envNumber({ PORT: ' 3000 ' }, 'PORT', 8787)).toBe(3000);
		expect(envNumber({ RETRIES: '0' }, 'RETRIES', 2)).toBe(0);
	});
});

describe('listen address', () => {
	test('binds to loopback unless HQ_HOST says otherwise', () => {
		expect(listenAddress({})).toEqual({ hostname: '127.0.0.1', port: 8787 });
		expect(listenAddress({ HQ_HOST: '0.0.0.0', PORT: '3000' })).toEqual({ hostname: '0.0.0.0', port: 3000 });
	});

	test('the local URL points at an address that answers', () => {
		expect(localUrl({})).toBe('http://localhost:8787');
		expect(localUrl({ HQ_HOST: '0.0.0.0', PORT: '3000' })).toBe('http://localhost:3000');
		expect(localUrl({ HQ_HOST: '192.168.1.5' }, 9000)).toBe('http://192.168.1.5:9000');
		expect(localUrl({ HQ_HOST: 'fd00::5' })).toBe('http://[fd00::5]:8787');
	});
});

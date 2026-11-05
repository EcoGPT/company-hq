import { describe, expect, test } from 'bun:test';
import { toolCallsInText } from '../src/assistant/text-tool-calls';

const known = (name: string) => ['add_reminder', 'add_task'].includes(name);
const strip = (calls: ReturnType<typeof toolCallsInText>) => calls.map(({ name, arguments: args }) => ({ name, args }));

describe('toolCallsInText', () => {
	test('reads the shapes open models print', () => {
		const plain = '{"name": "add_reminder", "arguments": {"text": "Ship it"}}';
		expect(strip(toolCallsInText(plain, known))).toEqual([{ name: 'add_reminder', args: { text: 'Ship it' } }]);
		expect(strip(toolCallsInText(`<tool_call>\n${plain}\n</tool_call>`, known))).toHaveLength(1);
		expect(strip(toolCallsInText('```json\n' + plain + '\n```', known))).toHaveLength(1);
		expect(strip(toolCallsInText('<think>hmm</think>\n' + plain, known))).toHaveLength(1);
		expect(strip(toolCallsInText('{"name":"add_task","parameters":"{\\"title\\":\\"x\\"}"}', known))).toEqual([
			{ name: 'add_task', args: { title: 'x' } },
		]);
		expect(
			strip(toolCallsInText('[{"name":"add_task","arguments":{}},{"name":"add_reminder","arguments":{}}]', known)),
		).toHaveLength(2);
	});

	test('reads several <tool_call> blocks, with or without prose around them', () => {
		const block = (name: string) => `<tool_call>\n{"name": "${name}", "arguments": {}}\n</tool_call>`;
		const both = `${block('add_task')}\n${block('add_reminder')}`;
		expect(strip(toolCallsInText(both, known)).map((c) => c.name)).toEqual(['add_task', 'add_reminder']);
		expect(strip(toolCallsInText(`Filing both now.\n${both}`, known))).toHaveLength(2);
		expect(toolCallsInText(`${block('add_task')}\n${block('unknown_tool')}`, known)).toEqual([]);
	});

	test('leaves real replies alone', () => {
		expect(toolCallsInText('Done. Filed it.', known)).toEqual([]);
		expect(toolCallsInText('Here is the payload: {"name":"add_task","arguments":{}}', known)).toEqual([]);
		expect(toolCallsInText('{"name":"unknown_tool","arguments":{}}', known)).toEqual([]);
		expect(toolCallsInText('{"title":"not a call"}', known)).toEqual([]);
		expect(toolCallsInText('[{"name":"add_task","arguments":{}}, 3]', known)).toEqual([]);
	});
});

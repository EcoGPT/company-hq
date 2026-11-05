import type { AiAdapters } from './ai/types';
import type { ResolvedAssistant } from './assistant/define';
import type { AppDefinition } from './apps/define';
import type { ConnectorDefinition } from './connectors/define';
import type { Provider } from './llm/types';

export type HqConfig = {
	assistant: ResolvedAssistant;
	apps?: AppDefinition[];
	connectors?: ConnectorDefinition[];
	provider?: Provider;
	ai?: AiAdapters;
};

export function defineConfig(config: HqConfig): HqConfig {
	return config;
}

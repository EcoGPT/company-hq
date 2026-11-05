import type { Migration } from '../db/database';
import { WIDGET_MIGRATIONS } from './store';

export { widgetRoutes } from './routes';
export { widgetWork } from './work';

/** Home-screen widgets. Ids start at `widgets/001`. */
export const migrations: Migration[] = WIDGET_MIGRATIONS;

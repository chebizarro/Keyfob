import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'jsdom',
    include: ['Extensions/**/__tests__/**/*.test.{js,ts}'],
  },
});

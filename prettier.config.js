module.exports = {
  arrowParens: 'always',
  printWidth: 100,
  singleQuote: true,
  trailingComma: 'all',
  useTabs: false,
  plugins: ['prettier-plugin-solidity'],
  overrides: [
    {
      files: ['src/**/*.sol', 'test/**/*.sol', 'script/**/*.sol'],
      options: {
        parser: 'solidity-parse',
        printWidth: 100,
        tabWidth: 4,
        useTabs: false,
        singleQuote: false,
        bracketSpacing: false,
        explicitTypes: 'always',
      },
    },
  ],
};
